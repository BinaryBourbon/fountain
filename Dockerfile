# syntax=docker/dockerfile:1.7
#
# Phoenix release image for Fountain (umbrella). Build stage compiles
# the `fountain_server` release against Erlang/OTP 28 + Elixir 1.19;
# runtime stage copies the release onto a slim Debian base.
#
# Notes:
#   - Umbrella: COPY apps/, config/, and the root mix.exs/mix.lock.
#     Release definition lives in the umbrella root (releases/0 in
#     mix.exs).
#   - No assets pipeline today: apps/fountain has no `assets/` dir and
#     no `mix assets.deploy` alias. If/when Tailwind+esbuild land,
#     add a `mix assets.deploy` step before `mix release`.
#   - SECRET_KEY_BASE is provided via the Infisical-materialized
#     fountain-secrets Secret (deployment.yaml envFrom). No fallback
#     generation here — fail-fast at boot if it's missing rather than
#     silently invalidate cookie sessions on every restart.

FROM hexpm/elixir:1.19.5-erlang-28.0.1-debian-bookworm-20260505-slim AS build

ENV MIX_ENV=prod

WORKDIR /app

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git \
 && rm -rf /var/lib/apt/lists/*

RUN mix local.hex --force \
 && mix local.rebar --force

# Umbrella deps live at the root.
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps ./apps

RUN mix deps.get --only prod \
 && mix deps.compile

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
# already-applied versions) so safe under rolling updates; the readiness
# probe gates traffic until migrate + start completes.
CMD ["/bin/sh", "-c", "/app/bin/fountain_server eval 'Fountain.Release.migrate()' && exec /app/bin/fountain_server start"]
