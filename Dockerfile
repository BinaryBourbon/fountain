# syntax=docker/dockerfile:1.7
#
# Phoenix release image for Fountain (umbrella). Build stage compiles
# the `fountain_server` release against Erlang/OTP 28 + Elixir 1.19;
# runtime stage copies the release onto a slim Debian base.
#
# Notes:
#   - Umbrella: COPY apps/, ee/, config/, and the root mix.exs/mix.lock.
#     Release definition lives in the umbrella root (releases/0 in
#     mix.exs).
#   - No assets pipeline today: apps/fountain has no `assets/` dir and
#     no `mix assets.deploy` alias. If/when Tailwind+esbuild land,
#     add a `mix assets.deploy` step before `mix release`.
#   - SECRET_KEY_BASE is provided via the Infisical-materialized
#     fountain-secrets Secret (deployment.yaml envFrom). No fallback
#     generation here — fail-fast at boot if it's missing rather than
#     silently invalidate cookie sessions on every restart.

FROM hexpm/elixir:1.19.2-erlang-28.3-debian-trixie-20260610-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

# Umbrella deps live at the root. Copy ONLY what dependency resolution
# reads — the root mix files, config, and each app's mix.exs — before
# fetching and compiling deps, so the (expensive, slow-moving) deps layer
# survives any change to application code. Copying apps/ wholesale here
# is what used to force a full dep recompile on every commit.
#
# coverage.exs is part of that set, not test-only config: both mix.exs
# files read it with Code.eval_file to build `test_coverage`, which runs
# while Mix loads the project — before any task, in every MIX_ENV. Leave
# it out and `mix deps.get` dies on Code.LoadError (#620 moved the
# settings into this file and the prod image stopped building).
COPY mix.exs mix.lock coverage.exs ./
COPY config ./config
COPY apps/fountain/mix.exs ./apps/fountain/mix.exs

RUN mix deps.get --only prod \
 && mix deps.compile

COPY apps ./apps
# ee/ is extra elixirc_paths for the fountain app (billing + transactional
# email — decisions/0010). Mix SILENTLY skips missing elixirc_paths dirs:
# without this COPY the release still builds but is missing those modules.
COPY ee ./ee
# Fountain.Docs embeds docs/ (and the CHANGELOG.md its changelog page
# includes) at compile time to serve them at /docs — without these the
# compile fails on File.read!. This is also the only way the content
# ships: the release never contains docs/ as files.
COPY docs ./docs
COPY CHANGELOG.md ./

RUN mix compile \
 && mix release fountain_server

# ---
# The `fountain` Go CLI. It is the ACP *child* a hosted buzz-acp harness drives
# (ADR 0020): buzz-acp runs `fountain acp`, which talks HTTP/SSE back to this
# same server. Built for the image's target arch (both amd64 and arm64).

FROM golang:1.25-bookworm AS gocli
WORKDIR /src
COPY cli/go.mod cli/go.sum ./
RUN go mod download
COPY cli/ ./
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH:-amd64}" \
      go build -trimpath -o /out/fountain ./cmd/fountain

# ---
# The hosted Buzz harness binary. block/buzz publishes an amd64 .deb only, so
# this is baked on amd64 and skipped on arm64 — an arm64 image simply has no
# buzz-acp, and runtime.exs leaves :buzz_acp_path unset there (the BootSweep is
# inert). Pin is deliberate: a moved tag under an agent's key is not something
# we want to float. Bump BUZZ_VERSION consciously.

FROM debian:bookworm-slim AS buzzacp
ARG TARGETARCH
ARG BUZZ_VERSION=0.5.14
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl ca-certificates dpkg \
 && mkdir -p /out \
 && if [ "${TARGETARCH:-amd64}" = "amd64" ]; then \
      curl -fsSL -o /tmp/buzz.deb \
        "https://github.com/block/buzz/releases/download/desktop-v${BUZZ_VERSION}/Buzz_${BUZZ_VERSION}_amd64.deb" \
      && dpkg-deb -x /tmp/buzz.deb /tmp/x \
      && install -m 0755 /tmp/x/usr/bin/buzz-acp /out/buzz-acp ; \
    else \
      echo "buzz-acp: no ${TARGETARCH} build published upstream; skipping bake" ; \
    fi \
 && rm -rf /var/lib/apt/lists/* /tmp/buzz.deb /tmp/x

# ---

FROM debian:trixie-slim AS runtime

# Git SHA of the source commit, surfaced in-app under the sidebar email
# popup so we can confirm at-a-glance which build is running (and that
# we're on home-cloud vs Render). Wired up by the build workflow; falls
# back to "dev" for local `docker build` invocations.
ARG BUILD_SHA=dev

ENV LANG=C.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000 \
    FOUNTAIN_BUILD_SHA=$BUILD_SHA

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates tini \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 1001 fountain \
 && useradd --system --uid 1001 --gid fountain --no-create-home fountain

WORKDIR /app

COPY --chown=fountain:fountain --from=build /app/_build/prod/rel/fountain_server ./

# Hosted Buzz harness binaries (ADR 0020). The `fountain` CLI is the harness's
# ACP child; buzz-acp is present only on amd64 (see the buzzacp stage). Copying
# an empty /out on arm64 is a no-op, so :buzz_acp_path stays unset there.
COPY --from=gocli /out/fountain /usr/local/bin/fountain
COPY --from=buzzacp /out/ /usr/local/lib/fountain-buzz/

ARG TARGETARCH
# Fail the build now if a baked binary will not run in this image, rather than
# at the first harness start. The CLI must run on every arch; buzz-acp only
# where it was baked.
RUN /usr/local/bin/fountain --version >/dev/null 2>&1 \
 && if [ -x /usr/local/lib/fountain-buzz/buzz-acp ]; then \
      /usr/local/lib/fountain-buzz/buzz-acp --help >/dev/null 2>&1 \
        || { echo "buzz-acp is present but will not run in this image" >&2; exit 1; } ; \
    fi

EXPOSE 4000

USER fountain

ENTRYPOINT ["/usr/bin/tini", "--"]
# Migrations run on every boot. Idempotent (Ecto.Migrator skips
# already-applied versions) and serialized by a Postgres advisory lock, so
# safe under rolling updates; the readiness probe gates traffic until
# migrate + start completes.
#
# MIGRATE_ON_BOOT=false turns this into a plain start, for a deployment that
# runs `bin/migrate` once in a Job instead (#610). `bin/migrate` ignores the
# switch — it is the Job's entrypoint.
CMD ["/bin/sh", "-c", "/app/bin/fountain_server eval 'Fountain.Release.migrate_on_boot()' && exec /app/bin/fountain_server start"]
