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

import_config "#{config_env()}.exs"
