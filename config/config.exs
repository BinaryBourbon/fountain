import Config

# Oban: durable background jobs. The Cron plugin elects a leader across the
# cluster itself, so scheduled work runs once regardless of replica count —
# the problem the Rehydrator solves by hand.
config :fountain, Oban,
  repo: Fountain.Repo,
  queues: [maintenance: 1, billing: 5],
  plugins: [
    # Oban's own job-table pruning: completed jobs older than 7 days.
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60},
    {Oban.Plugins.Cron,
     crontab: [
       # 04:23 UTC — after the 03:17 database backup, so pruning never races
       # the dump and a backup always captures the pre-prune state.
       {"23 4 * * *", Fountain.Workers.RetentionPruner},
       # Hourly: a leaked sprite costs money and a stuck sandbox row holds
       # tenant quota, so the gap between the leak and its cleanup is what
       # matters. Each run is one paginated list plus at most a handful of
       # deletes.
       {"7 * * * *", Fountain.Workers.SandboxReaper}
     ]}
  ]

# Self-hosting switches. Defaults preserve the hosted behaviour; a self-hoster
# turns billing off and closes registration without patching source.
config :fountain,
  billing_enabled: true,
  registration_enabled: true,
  registration_allowed_email_domains: []

# Sandbox lifetime bounds. A sandbox used to live until something explicitly
# terminated it; production had one idle for 83 days. Reclaiming only tears down
# the sandbox — the conversation stays resumable and the next prompt provisions
# a fresh one — so the cost of being wrong here is a re-provision, not lost
# work. Set either to 0 to disable. See Fountain.Conversations.Lifecycle.
config :fountain,
  sandbox_idle_timeout_minutes: 60,
  sandbox_max_lifetime_hours: 24

config :fountain,
  ecto_repos: [Fountain.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

config :fountain, FountainWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: FountainWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Fountain.PubSub,
  live_view: [signing_salt: "DtUggWta"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :remote_ip]

config :phoenix, :json_library, Jason

# Swoosh mailer
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Local

# Ueberauth — GitHub OAuth strategy.
# `base_path` matches the router prefix in router.ex (`/auth/oauth/:provider`);
# without it the plug ignores the requests and the controller's :request
# action runs directly, redirecting users back to /auth/login.
config :ueberauth, Ueberauth,
  base_path: "/auth/oauth",
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

import_config "#{config_env()}.exs"
