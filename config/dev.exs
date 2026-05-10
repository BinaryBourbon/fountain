import Config

config :fountain, Fountain.Repo,
  url: System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/fountain_dev"),
  pool_size: 5,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true

config :fountain, FountainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: false,
  code_reloader: true,
  debug_errors: true,
  secret_key_base: "bmGGpaMgppY49MzfYw004Q7FF6QCYP7hBk7dDV8H8nvNp/dTwb/YTDZ5LOHENZWk",
  watchers: []

config :fountain, dev_routes: true
config :fountain, cache_api_spec: false

# Swoosh local mailbox in dev — browse sent emails at /dev/mailbox
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Local
config :swoosh, :api_client, false

config :logger, :default_formatter, format: "[$level] $message\n"

config :phoenix, :stacktrace_depth, 20
config :phoenix, :plug_init_mode, :runtime
