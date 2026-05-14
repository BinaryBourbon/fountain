import Config

# Load .env in dev/test
env_path = Path.join(File.cwd!(), ".env")

if config_env() != :prod and File.exists?(env_path) do
  env_path
  |> File.stream!()
  |> Enum.each(fn line ->
    line = String.trim(line)

    cond do
      line == "" ->
        :ok

      String.starts_with?(line, "#") ->
        :ok

      true ->
        case String.split(line, "=", parts: 2) do
          [k, v] ->
            v = v |> String.trim() |> String.trim_leading("\"") |> String.trim_trailing("\"")
            if System.get_env(k) in [nil, ""], do: System.put_env(k, v)

          _ ->
            :ok
        end
    end
  end)
end

server? = System.get_env("PHX_SERVER") in ~w(1 true yes)

if server? do
  config :fountain, FountainWeb.Endpoint, server: true
end

config :fountain, FountainWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

env = config_env()

master_secrets_key =
  case {System.get_env("MASTER_SECRETS_KEY"), env, server?} do
    {nil, :prod, true} ->
      raise "environment variable MASTER_SECRETS_KEY is missing (32 bytes, url-safe base64, no padding). " <>
              "Generate: openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='"

    {nil, _, _} ->
      :crypto.hash(:sha256, "fountain:dev:master_secrets_key")

    {encoded, _, _} ->
      case Base.url_decode64(encoded, padding: false) do
        {:ok, <<_::binary-32>> = key} ->
          key

        _ ->
          raise "MASTER_SECRETS_KEY must be 32 bytes encoded as url-safe base64 (no padding)."
      end
  end

config :fountain, :master_secrets_key, master_secrets_key
config :fountain, :sprites_token, System.get_env("SPRITES_TOKEN")
config :fountain, :public_url, System.get_env("FOUNTAIN_DOMAIN", "http://localhost:4000")
# Inference credentials are per-user (BYO, ADR 0008) and live in the
# inference_credentials table — no platform-level env vars for them.

cluster_topologies =
  case System.get_env("CLUSTER_DNS_QUERY") do
    nil ->
      []

    "" ->
      []

    query ->
      [
        fountain: [
          strategy: Cluster.Strategy.DNSPoll,
          config: [
            polling_interval: 5_000,
            query: query,
            node_basename: System.get_env("RELEASE_NAME", "fountain")
          ]
        ]
      ]
  end

config :libcluster, topologies: cluster_topologies

# GitHub OAuth (§2.4)
# base_path must match the router prefix in router.ex (/auth/oauth/:provider).
config :ueberauth, Ueberauth,
  base_path: "/auth/oauth",
  providers: [
    github: {Ueberauth.Strategy.Github, [default_scope: "user:email"]}
  ]

config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: System.get_env("GITHUB_OAUTH_CLIENT_ID"),
  client_secret: System.get_env("GITHUB_OAUTH_CLIENT_SECRET")

# Stripe (§5.2)
config :stripity_stripe,
  api_key: System.get_env("STRIPE_SECRET_KEY"),
  webhook_secret: System.get_env("STRIPE_WEBHOOK_SECRET")

# Stripe Price ID for the subscription tier surfaced by Checkout.
# Set per environment (test-mode price in dev, live-mode price in prod).
config :fountain, :stripe_price_id, System.get_env("STRIPE_PRICE_ID")

# Swoosh Resend adapter for prod; overridden to Local/Test in dev/test via env configs.
# Domain (updates.inevitable.fyi) must be verified in Resend with SPF/DKIM/DMARC DNS
# records before the configured EMAIL_FROM address can deliver.
if config_env() == :prod do
  config :fountain, :email_from, System.get_env("EMAIL_FROM", "noreply@updates.inevitable.fyi")

  if api_key = System.get_env("RESEND_API_KEY") do
    config :fountain, Fountain.Mailer,
      adapter: Swoosh.Adapters.Resend,
      api_key: api_key
  end
end

if config_env() == :prod and server? do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise "environment variable DATABASE_URL is missing."

  config :fountain, Fountain.Repo,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    ssl: true,
    ssl_opts: [verify: :verify_none]

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise "environment variable SECRET_KEY_BASE is missing."

  host = System.get_env("FOUNTAIN_DOMAIN") || "localhost"

  config :fountain, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :fountain, FountainWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    secret_key_base: secret_key_base

  # ── OpenTelemetry ─────────────────────────────────────────────────────────────────────────
  #
  # Export traces via OTLP (HTTP/protobuf). Reads standard OTEL env vars:
  #   OTEL_SERVICE_NAME          — defaults to "fountain"
  #   OTEL_EXPORTER_OTLP_ENDPOINT — e.g. "https://api.honeycomb.io"
  #   OTEL_EXPORTER_OTLP_HEADERS  — e.g. "x-honeycomb-team=<key>"
  #
  # For Honeycomb specifically you can also set HONEYCOMB_API_KEY and the
  # exporter config below will wire it up automatically.
  otel_endpoint =
    System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT") ||
      System.get_env("HONEYCOMB_ENDPOINT", "https://api.honeycomb.io")

  # Parse "key=val,key2=val2" header strings produced by OTEL_EXPORTER_OTLP_HEADERS,
  # then layer on Honeycomb-specific headers if HONEYCOMB_API_KEY is set.
  otel_headers =
    case System.get_env("OTEL_EXPORTER_OTLP_HEADERS") do
      nil ->
        []

      raw ->
        raw
        |> String.split(",")
        |> Enum.flat_map(fn pair ->
          case String.split(pair, "=", parts: 2) do
            [k, v] -> [{String.trim(k), String.trim(v)}]
            _ -> []
          end
        end)
    end

  otel_headers =
    case System.get_env("HONEYCOMB_API_KEY") do
      nil -> otel_headers
      key -> [{"x-honeycomb-team", key} | otel_headers]
    end

  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    resource: [
      {"service.name", System.get_env("OTEL_SERVICE_NAME", "fountain")},
      {"deployment.environment", System.get_env("FLY_APP_NAME", "prod")}
    ]

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: otel_endpoint,
    otlp_headers: otel_headers
end
