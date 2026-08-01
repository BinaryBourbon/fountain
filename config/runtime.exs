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

# The dev fallback below is derived from a constant committed to this repo, so it
# must never be reachable in :prod. The guard is deliberately on config_env()
# alone — gating it on `server?` too would hand that public key to every prod
# process started without PHX_SERVER=true (release eval tasks, migrations, seeds,
# a remote console), and any of those can create a tenant DEK.
master_secrets_key =
  case {System.get_env("MASTER_SECRETS_KEY"), env} do
    {nil, :prod} ->
      raise "environment variable MASTER_SECRETS_KEY is missing (32 bytes, url-safe base64, no padding). " <>
              "Generate: openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='"

    {nil, _} ->
      :crypto.hash(:sha256, "fountain:dev:master_secrets_key")

    {encoded, _} ->
      case Base.url_decode64(encoded, padding: false) do
        {:ok, <<_::binary-32>> = key} ->
          key

        _ ->
          raise "MASTER_SECRETS_KEY must be 32 bytes encoded as url-safe base64 (no padding)."
      end
  end

config :fountain, :master_secrets_key, master_secrets_key
config :fountain, :sprites_token, System.get_env("SPRITES_TOKEN")

# Two different shapes are needed and they are not interchangeable:
#
#   :public_url — absolute, scheme-ful. Used to build links that leave the app
#                 (verification/reset emails, llms.txt) and as FOUNTAIN_BASE_URL
#                 inside every sprite.
#   :phx_host   — bare host. Used for the endpoint url and check_origin.
#
# `FOUNTAIN_DOMAIN` was used verbatim for both, and every shipped example sets
# it bare (render.yaml, fly.toml, k8s/deployment.yaml), so :public_url came out
# schemeless — "fountain.example.com/users/confirm/<token>" is not a link, and
# a schemeless FOUNTAIN_BASE_URL is not resolvable by the in-sprite client.
#
# PUBLIC_URL and PHX_HOST are the explicit replacements. FOUNTAIN_DOMAIN still
# works and is normalised into whichever shape is being asked for, so existing
# deployments keep booting and get correct links without an env change.
default_scheme = if env == :prod, do: "https", else: "http"

public_url =
  Fountain.PublicUrl.absolute(
    System.get_env("PUBLIC_URL") || System.get_env("FOUNTAIN_DOMAIN"),
    default_scheme
  )

phx_host =
  case System.get_env("PHX_HOST") do
    blank when blank in [nil, ""] -> Fountain.PublicUrl.host(public_url)
    host -> host
  end

config :fountain, :public_url, public_url
config :fountain, :phx_host, phx_host

# Prometheus scrape endpoint, served on its own port by FountainWeb.MetricsPlug
# rather than through the public endpoint. Defaults to on in prod and off
# elsewhere, so dev and test never bind a stray listener.
metrics_port =
  case System.get_env("METRICS_PORT") do
    nil -> if env == :prod, do: 9568, else: nil
    "" -> nil
    "0" -> nil
    port -> String.to_integer(port)
  end

config :fountain, :metrics_port, metrics_port

# CIDRs treated as proxies when resolving the client IP from X-Forwarded-For.
# Only widen this to cover addresses that are genuinely proxies — anything
# trusted here is stepped over, so an over-broad list lets a client spoof its
# way past rate limiting.
if proxies = System.get_env("TRUSTED_PROXIES") do
  config :fountain,
         :trusted_proxies,
         proxies |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end

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

# Mail delivery.
#
# With no adapter configured this used to silently fall back to
# Swoosh.Adapters.Local — an in-memory mailbox with no preview route in prod. So
# the verification email went nowhere, and since login is refused while
# email_verified_at is nil, the very first signup on a fresh instance
# dead-ended with nothing pointing at the cause. Silence is the worst possible
# behaviour here, so an unconfigured production instance now refuses to boot and
# says what to do about it.
#
# Resend is the hosted option. SMTP is the one that matters for self-hosting —
# it was named in the launch checklist and the engineering plan and never
# actually implemented, so operators were told to set SMTP_* variables that did
# nothing.
if config_env() == :prod do
  config :fountain, :email_from, System.get_env("EMAIL_FROM", "noreply@updates.inevitable.fyi")

  cond do
    api_key = System.get_env("RESEND_API_KEY") ->
      config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Resend, api_key: api_key

    smtp_host = System.get_env("SMTP_HOST") ->
      config :fountain, Fountain.Mailer,
        adapter: Swoosh.Adapters.SMTP,
        relay: smtp_host,
        port: String.to_integer(System.get_env("SMTP_PORT", "587")),
        username: System.get_env("SMTP_USERNAME"),
        password: System.get_env("SMTP_PASSWORD"),
        # STARTTLS by default; set SMTP_TLS=never for a relay on a trusted
        # network that does not offer it.
        tls: String.to_atom(System.get_env("SMTP_TLS", "always")),
        auth: if(System.get_env("SMTP_USERNAME"), do: :always, else: :never),
        retries: 2

    System.get_env("EMAIL_DELIVERY") == "none" ->
      # Explicit opt-out, for an instance that only uses OAuth sign-in or is
      # being evaluated. Accounts created with email + password cannot verify
      # themselves in this mode; see Fountain.Release.verify_email/1.
      # IO.puts rather than IO.warn: a stacktrace here points at config code and
      # tells the operator nothing.
      IO.puts(:stderr, """

      [fountain] EMAIL_DELIVERY=none — email is disabled.

      Verification and password-reset emails will not be delivered. Accounts
      created with email + password cannot complete signup unless an operator
      verifies them:

          bin/fountain_server eval 'Fountain.Release.verify_email("you@example.com")'
      """)

    true ->
      raise """
      No mail delivery is configured.

      Verification and password-reset emails would be discarded, and signup
      would dead-end with no visible error. Set one of:

        RESEND_API_KEY=...                 hosted delivery via Resend
        SMTP_HOST=... SMTP_PORT=587        any SMTP server
          SMTP_USERNAME=... SMTP_PASSWORD=...
        EMAIL_DELIVERY=none                deliberately disable email

      With EMAIL_DELIVERY=none, verify the first account manually:

          bin/fountain_server eval 'Fountain.Release.verify_email("you@example.com")'
      """
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

  host = phx_host

  config :fountain, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Scheme and port come from PUBLIC_URL rather than being pinned to https/443,
  # so a self-hoster terminating on plain HTTP or a non-standard port generates
  # correct URLs. For the hosted deployment PUBLIC_URL is https, and URI.parse
  # fills in 443, so this is byte-identical to the previous hardcoding.
  public_uri = URI.parse(public_url)

  config :fountain, FountainWeb.Endpoint,
    url: [host: host, port: public_uri.port || 443, scheme: public_uri.scheme || "https"],
    http: [ip: {0, 0, 0, 0, 0, 0, 0, 0}],
    # check_origin guards the LiveView websocket/longpoll handshake. Setting an
    # explicit list replaces the default (the endpoint's own host), so we must
    # re-list it here. `//*.replit.dev` allows Replit preview/dev subdomains.
    check_origin: [
      "//#{host}",
      "//*.replit.dev"
    ],
    secret_key_base: secret_key_base

  # ── OpenTelemetry ─────────────────────────────────────────────────────────
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
