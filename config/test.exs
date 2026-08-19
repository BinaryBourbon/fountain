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

# The registry settle window (#800) is a real-time wait; keep tests brisk.
config :fountain, :conversation_registry_settle_ms, 150

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Swoosh test adapter — use Swoosh.TestAssertions in tests
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Test
config :swoosh, :api_client, false

# Pinned so a developer's shell (EMAIL_DELIVERY / FIRST_USER_ADMIN /
# MIGRATE_ON_BOOT) can't change suite behavior; tests toggle these through
# the application env.
config :fountain, :email_enabled, true
config :fountain, :first_user_admin, false
config :fountain, :migrate_on_boot, true

# Jobs are asserted with Oban.Testing rather than executed as a side effect.
config :fountain, Oban, testing: :manual

# OAuth clients (#818) the controller tests register against.
config :fountain, :oauth_clients, [
  %{
    id: "test-app",
    name: "Test App",
    redirect_uris: ["https://app.test/callback", "http://localhost:5173/"]
  }
]

# Self-hosted runners (ADR 0022) are enabled by default in every other env —
# there is no credential to be missing. Off here so the suite's assumptions
# about "which providers are enabled" (only what a test configures) hold;
# runner tests switch it on explicitly.
config :fountain, :runners_enabled, false

# Teammate email + phone (flag `team_comms`) and the PostHog flag lookup:
# every outbound call goes to a Req.Test plug, so a test that forgets to
# stub fails loudly instead of reaching a real provider. The keys are set so
# `Comms.configured?/0` holds; the flag itself stays off (no override, no
# PostHog key) until a test flips `:feature_flag_overrides`.
config :fountain, :agentmail_api_key, "am_test_key"
config :fountain, :agentmail_req_options, plug: {Req.Test, Fountain.Team.Comms.AgentMail}
config :fountain, :agentphone_api_key, "ap_test_key"
config :fountain, :agentphone_req_options, plug: {Req.Test, Fountain.Team.Comms.AgentPhone}
config :fountain, :agentphone_webhook_secret, "whsec_test"
config :fountain, :posthog_req_options, plug: {Req.Test, Fountain.FeatureFlags}
