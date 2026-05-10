import Config

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
  metadata: [:request_id]

config :phoenix, :json_library, Jason

# Swoosh mailer
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Local

# Ueberauth — GitHub OAuth strategy
config :ueberauth, Ueberauth,
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

import_config "#{config_env()}.exs"
