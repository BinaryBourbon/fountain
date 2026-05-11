import Config

config :fountain, Fountain.Repo,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/fountain_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 20

config :fountain, FountainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "c4S1HEBb+LhhInAgMbEJdXVBSKK65S7Mk9oeXrPTn65slnwVQU5zFqCT3p2wqWaR",
  server: false

config :fountain, :skip_rehydrate, true
config :fountain, :checkpoint_creation_enabled, false

# Skip the Ueberauth plug so tests can set :ueberauth_auth/:ueberauth_failure
# directly without triggering a real OAuth network round-trip.
config :fountain, :ueberauth_test_mode, true

# Key rate limit buckets by calling process PID instead of IP, so async
# ExUnit tests don't share counters. Each test runs in its own process.
config :fountain, :rate_limit_test_isolation, true

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Swoosh test adapter — use Swoosh.TestAssertions in tests
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

# Point excoveralls at the repo-root coveralls.json regardless of which
# app directory Mix happens to have as cwd when the settings are loaded.
config :excoveralls, config_file: Path.expand("../coveralls.json", __DIR__)
