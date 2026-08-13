import Config

# Oban: durable background jobs. The Cron plugin elects a leader across the
# cluster itself, so scheduled work runs once regardless of replica count —
# the problem the Rehydrator solves by hand.
config :fountain, Oban,
  repo: Fountain.Repo,
  # exports is its own queue so a user-requested data export is never stuck
  # behind a maintenance sweep; concurrency 1 because each job reads every row
  # an account owns and two at once doubles that memory.
  queues: [maintenance: 1, billing: 5, exports: 1, mailer: 5],
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
       {"7 * * * *", Fountain.Workers.SandboxReaper},
       # 05:41 UTC — after the 03:17 backup and the 04:23 retention prune, so
       # a backup always captures the accounts before the sweep removes them.
       {"41 5 * * *", Fountain.Workers.UnverifiedAccountPruner},
       # 06:53 UTC — backstop for trials Stripe never closed out (#504). The
       # 48h grace inside the sweep means Stripe's webhook retries always get
       # the first shot; daily is fast enough for a backstop. The worker
       # no-ops when billing is disabled.
       {"53 6 * * *", Fountain.Workers.TrialSweeper}
     ]}
  ]

# Self-hosting switches. In dev and prod, runtime.exs overrides billing from
# BILLING_ENABLED — off unless set (#336); the hosted deployment opts in via
# k8s/deployment.yaml. The `true` here reaches only :test (runtime.exs skips
# the override there), where config/test.exs also pins it, so the suite
# exercises the gate as enforced and flips it off per-test.
config :fountain,
  billing_enabled: true,
  registration_enabled: true,
  registration_allowed_email_domains: []

# Sandbox lifetime bounds. Crossing the idle bound SUSPENDS the sandbox — the
# sprite stays (scaled to zero) and the next prompt resumes the agent with its
# memory intact, so this bound is free to be aggressive. Crossing the
# max-lifetime ceiling DESTROYS the sprite, and the agent's session with it
# (#649) — it exists to bound runaway busy compute. Set either to 0 to
# disable. See Fountain.Conversations.Lifecycle and decisions/0017.
config :fountain,
  sandbox_idle_timeout_minutes: 60,
  sandbox_max_lifetime_hours: 24

config :fountain,
  ecto_repos: [Fountain.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# Take the migration lock as a Postgres advisory lock rather than Ecto's
# default `FOR UPDATE` on `schema_migrations` (#610). The default cannot
# serialize the one moment that matters: on a virgin database the table it
# locks does not exist yet, so two replicas booting together both reach
# `CREATE TABLE schema_migrations` and the loser dies on the type's unique
# index. An advisory lock is taken before anything touches the table, so the
# bootstrap is serialized like every migration after it.
config :fountain, Fountain.Repo, migration_lock: :pg_advisory_lock

# Whether a booting release runs pending migrations before it serves. True
# here so the shipped single-replica image needs no configuration;
# runtime.exs turns it off for MIGRATE_ON_BOOT=false, the deployment that
# runs migrations once in a Job instead. See Fountain.Release.migrate_on_boot/0.
config :fountain, :migrate_on_boot, true

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

# Whether this instance can deliver email at all. Flipped to false only by
# EMAIL_DELIVERY=none in runtime.exs; registration auto-verifies accounts when
# it is false, because a verification link that cannot be delivered gates
# nothing.
config :fountain, :email_enabled, true

# Self-host bootstrap (ADR 0011): when true, the first account to become
# verified on an instance with no admin is promoted to admin. Off everywhere
# unless FIRST_USER_ADMIN=true is set at boot.
config :fountain, :first_user_admin, false

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
