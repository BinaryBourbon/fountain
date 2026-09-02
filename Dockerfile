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
# One line per umbrella library app (decisions/0037): the umbrella loads every
# child's mix.exs to resolve deps, so a missing one fails `mix deps.get` here.
# umbrella_layout_test.exs checks that every apps/managoat_* has its line.
COPY apps/managoat_broker/mix.exs ./apps/managoat_broker/mix.exs
COPY apps/managoat_docs/mix.exs ./apps/managoat_docs/mix.exs
COPY apps/managoat_runner/mix.exs ./apps/managoat_runner/mix.exs

RUN mix deps.get --only prod \
 && mix deps.compile

COPY apps ./apps
# ee/ is extra elixirc_paths for the fountain app (billing + transactional
# email — decisions/0010). Mix SILENTLY skips missing elixirc_paths dirs:
# without this COPY the release still builds but is missing those modules.
COPY ee ./ee
# Fountain.Docs embeds docs/ at compile time to serve it at /docs — without
# it the compile fails on File.read!. This is also the only way the content
# ships: the release never contains docs/ as files.
#
# Every file Fountain.Docs reads at compile time has to be here too, and two of
# those paths reach outside docs/: the changelog page snippet-includes
# CHANGELOG.md, and the tour page includes the SDK example it is written from.
# A missing one is not a broken link, it is a failed image build —
# `docs_test.exs` checks this list against the module's @external_resource
# attributes so the failure lands in CI instead.
COPY docs ./docs
COPY CHANGELOG.md ./
COPY sdk/typescript/examples ./sdk/typescript/examples

# Lumis downloads a language's tree-sitter parser on first use and caches it
# under its own priv/. The deployment runs read-only (deployment.yaml sets
# `readOnlyRootFilesystem: true`), so at runtime that download can neither
# happen nor be kept, and every fenced block in /docs and /help renders
# unhighlighted — how #879 shipped. Caching the parsers here, before the
# release is assembled, puts them in `deps/lumis/priv/lumis`, which `mix
# release` copies in like any other dependency's priv. `{:ok, _}` is the point:
# a parser that cannot be fetched fails the build rather than the page.
# `elixir -e` rather than `mix run`: any mix task here evaluates
# config/runtime.exs, which demands MASTER_SECRETS_KEY and the rest of the
# production environment that does not exist during a build. Prepending the
# compiled ebin paths gives the same code without the config.
RUN mix compile \
 && elixir -e 'Enum.each(Path.wildcard("_build/prod/lib/*/ebin"), &Code.prepend_path/1); {:ok, _} = Application.ensure_all_started(:lumis); {:ok, _} = Lumis.Languages.cache(Fountain.Docs.languages())' \
 && mix release fountain_server

# ---
# The `fountain` Go CLI. It is the ACP *child* a hosted buzz-acp harness drives
# (ADR 0020): buzz-acp runs `fountain acp`, which talks HTTP/SSE back to this
# same server. Built for the image's target arch (both amd64 and arm64).

FROM golang:1.27-bookworm AS gocli
WORKDIR /src
COPY cli/go.mod cli/go.sum ./
RUN go mod download
COPY cli/ ./
ARG TARGETARCH
RUN CGO_ENABLED=0 GOOS=linux GOARCH="${TARGETARCH:-amd64}" \
      go build -trimpath -o /out/fountain ./cmd/fountain

# ---
# The hosted Buzz harness binary. block/buzz publishes an amd64 .deb only, and
# our cluster is arm64 (ADR 0020, #743), so we build buzz-acp ourselves for both
# arches from the block/buzz source and publish it as a Fountain release asset
# (`.github/workflows/buzz-acp-publish.yml`). Here we just download the
# arch-matched binary and verify its checksum — no compile in the image build.
# The pin lives in buzz-acp.version and is passed as BUZZ_ACP_VERSION by the
# build workflow; the default below keeps a local `docker build` working.
# (buzz-acp.source may point the publish workflow at a fork — the version is
# then only the release name; see that workflow. #776 tracks repinning to
# upstream once block/buzz#6088 ships.)

FROM debian:trixie-slim AS buzzacp
ARG TARGETARCH
ARG BUZZ_ACP_VERSION=0.5.14-fountain.4
# buzz-acp: the hosted harness (gate 2). buzz: the CLI the server-side MCP tools
# shell out to for signed publishes (gate 3, #737). Both from our own release.
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && mkdir -p /out \
 && base="https://github.com/BinaryBourbon/fountain/releases/download/buzz-acp-v${BUZZ_ACP_VERSION}" \
 && for bin in buzz-acp buzz; do \
      asset="${bin}-linux-${TARGETARCH:-amd64}" \
      && curl -fsSL -o "/out/${bin}" "${base}/${asset}" \
      && curl -fsSL -o /tmp/sha "${base}/${asset}.sha256" \
      && echo "$(cat /tmp/sha)  /out/${bin}" | sha256sum -c - \
      && chmod 0755 "/out/${bin}" ; \
    done \
 && rm -rf /var/lib/apt/lists/* /tmp/sha

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

# Hosted Buzz binaries (ADR 0020, #737). The `fountain` CLI is the harness's ACP
# child; buzz-acp is the harness; buzz is the CLI the server-side MCP tools shell
# out to for signed publishes. All our own builds (see the stages) for both arches.
COPY --from=gocli /out/fountain /usr/local/bin/fountain
COPY --from=buzzacp /out/buzz-acp /usr/local/lib/fountain-buzz/buzz-acp
COPY --from=buzzacp /out/buzz /usr/local/lib/fountain-buzz/buzz

# Fail the build now if a baked binary will not run in this image, rather than
# at the first harness start or publish.
RUN /usr/local/bin/fountain --version >/dev/null 2>&1 \
 && /usr/local/lib/fountain-buzz/buzz-acp --help >/dev/null 2>&1 \
 && /usr/local/lib/fountain-buzz/buzz --help >/dev/null 2>&1 \
      || { echo "a baked binary will not run in this image" >&2; exit 1; }

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
