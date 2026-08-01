import Config

config :logger, level: :info

# Phoenix's request logger was disabled here, which — combined with traces
# switched off at the deployment and no metrics reporter — meant production
# emitted no record of HTTP requests at all. It is the cheapest signal there is
# and Alloy already ships pod logs to Loki, so it goes back on. Set
# PHOENIX_REQUEST_LOG=false at the deployment if it ever needs muting again,
# rather than editing this file.
config :phoenix, :logger, System.get_env("PHOENIX_REQUEST_LOG") != "false"
