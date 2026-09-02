# The fixture image's build stage: what a host's Dockerfile COPYs before
# `mix compile`. The Dockerfile guardrails check the manual's compile-time
# reads against these lines.
FROM elixir:1.19 AS build
WORKDIR /app
COPY mix.exs ./
COPY --from=deps /deps ./deps
COPY test/fixtures/manual ./test/fixtures/manual
COPY test/fixtures/snippets/CHANGELOG.md ./test/fixtures/snippets/CHANGELOG.md
RUN mix compile
