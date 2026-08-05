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

# A fake client id so FountainWeb.OAuth.github_configured?/0 is true and the
# "Continue with GitHub" button renders in tests (#336). Inert: the test mode
# above means no real OAuth round-trip ever happens.
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test-github-client-id",
  client_secret: "test-github-client-secret"

# The runtime BILLING_ENABLED switch defaults to off (#336) but is not applied
# in :test (see config/runtime.exs) — the suite pins the gate on here and
# toggles it per-test via the application env.
config :fountain, :billing_enabled, true

# Legal identity pinned (LEGAL_* env vars are not read in :test — see
# config/runtime.exs) so the developer's shell can't change suite behavior;
# unpublished-page tests set :legal to nil through the application env.
config :fountain, :legal, %{
  entity: "Test Legal Entity LLC",
  contact_email: "legal@example.com",
  jurisdiction: "the State of Testing",
  updated: "2026-01-01"
}

# A known webhook secret so StripeWebhookController's fail-closed secret
# resolution (#390) succeeds; signature-path tests sign payloads with the
# value they read back from this key, exercising the real construct_event.
config :stripity_stripe, webhook_secret: "whsec_test_signing_secret"

# Key rate limit buckets by calling process PID instead of IP, so async
# ExUnit tests don't share counters. Each test runs in its own process.
config :fountain, :rate_limit_test_isolation, true

# The funnel telemetry poller queries the DB outside any test's SQL Sandbox
# ownership; keep it off here (Fountain.Funnel is tested directly).
config :fountain, :funnel_poller_enabled, false

# Fountain.Retry sleeps between attempts; 1ms keeps retry-path tests fast
# without changing the retry logic under test.
config :fountain, :retry_base_ms, 1

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Swoosh test adapter — use Swoosh.TestAssertions in tests
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

# Pinned so a developer's shell (EMAIL_DELIVERY / FIRST_USER_ADMIN) can't
# change suite behavior; tests toggle these through the application env.
config :fountain, :email_enabled, true
config :fountain, :first_user_admin, false

# Point excoveralls at the repo-root coveralls.json regardless of which
# app directory Mix happens to have as cwd when the settings are loaded.
config :excoveralls, config_file: Path.expand("../coveralls.json", __DIR__)

# Jobs are asserted with Oban.Testing rather than executed as a side effect.
config :fountain, Oban, testing: :manual
