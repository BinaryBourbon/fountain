import Config

config :fountain, Fountain.Repo,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/fountain_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 5

config :fountain, FountainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "c4S1HEBb+LhhInAgMbEJdXVBSKK65S7Mk9oeXrPTn65slnwVQU5zFqCT3p2wqWaR",
  server: false

config :fountain, :skip_rehydrate, true
config :fountain, :checkpoint_creation_enabled, false
config :fountain, :rate_limit_enabled, false

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Swoosh test adapter — use Swoosh.TestAssertions in tests
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false
