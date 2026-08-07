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

FROM hexpm/elixir:1.19.2-erlang-28.3-debian-bookworm-20260505-slim AS build

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
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/fountain/mix.exs ./apps/fountain/mix.exs

RUN mix deps.get --only prod \
 && mix deps.compile

COPY apps ./apps
# ee/ is extra elixirc_paths for the fountain app (billing + transactional
# email — decisions/0010). Mix SILENTLY skips missing elixirc_paths dirs:
# without this COPY the release still builds but is missing those modules.
COPY ee ./ee

RUN mix compile \
 && mix release fountain_server

# ---

FROM debian:bookworm-slim AS runtime

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
