# Configuration reference

Every environment variable the server reads at runtime, grouped by concern.
Variables are read at boot — changing one means restarting the app.

This list is complete by construction: a test fails the build when
`config/runtime.exs` reads a variable that is not documented on this page, so
the reference cannot silently drift from the code.

A few variables **refuse to boot on an invalid value** rather than falling
back to a default — noted per row. That is deliberate: a typo that silently
disabled a bound or a key would otherwise surface as a bill or a breach, not
an error message.

---

## Core

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_URL` | — | prod | Postgres connection string. Boot fails without it |
| `SECRET_KEY_BASE` | — | prod (serving) | Signs and encrypts session cookies and tokens. Generate: `openssl rand -base64 48` |
| `MASTER_SECRETS_KEY` | — | prod | Wraps every tenant's data-encryption key ([the secrets model](architecture.md#the-secrets-model)). 32 bytes, url-safe base64, no padding: `openssl rand 32 \| base64 \| tr '+/' '-_' \| tr -d '='`. **Lose it and every stored secret is unrecoverable.** Boot refuses a malformed value |
| `PUBLIC_URL` | — | prod | The externally visible base URL, scheme included. A prod instance refuses to boot without it (or the deprecated `FOUNTAIN_DOMAIN`) — the old `http://localhost:4000` fallback silently put localhost links in every verification email. Builds every link that leaves the app (verification and reset emails, `llms.txt`) and is passed to every sandbox as `FOUNTAIN_BASE_URL`. An `https://` value also switches on HTTPS redirection, HSTS, and the secure cookie flag — all derived from the scheme |
| `PHX_HOST` | host of `PUBLIC_URL` | — | Bare host for the endpoint URL and the LiveView origin check. Set only if it differs from `PUBLIC_URL`'s host |
| `FOUNTAIN_DOMAIN` | — | deprecated | The old combined variable; still honoured as a fallback for both of the above. Prefer `PUBLIC_URL` / `PHX_HOST` |
| `PHX_SERVER` | `true` in the shipped image | — | `1`/`true`/`yes` starts the web listener. Release tasks run with `PHX_SERVER=false … eval '…'` to boot the app without binding the port |
| `PORT` | `4000` | — | HTTP listen port |

## Database

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_SSL` | `true` | — | TLS to Postgres. Set `false` for a stock `postgres` container, which does not serve TLS |
| `DATABASE_SSL_VERIFY` | off | — | Unset, the connection is encrypted but the server certificate is **not** verified. `true` verifies it, against the OS trust store unless a CA file is given |
| `DATABASE_SSL_CA_FILE` | OS trust store | — | CA bundle used when `DATABASE_SSL_VERIFY=true` |
| `POOL_SIZE` | `10` | — | Database connection pool size |
| `MIGRATE_ON_BOOT` | `true` | — | Whether a booting release runs pending migrations before it serves. `false` (also `0`, `no`) makes the pod only serve, for the deployment that runs migrations once in a Job — see [migrations in a Job](self-hosting.md#running-migrations-in-a-job). `bin/migrate` always migrates, whatever this is set to. **Nothing checks that the Job ran**: a pod that skips migrations against an un-migrated database boots and then fails on the first query |

## Sandboxes

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SPRITES_TOKEN` | — | for conversations | Platform token for [sprites.dev](https://sprites.dev). The app boots without it, but every conversation fails. Never expose it to tenants — it pays for every sandbox |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | — | Repoints the sandbox API. Anything else must implement the same contract; there is no bundled alternative |
| `SPRITES_TIMEOUT_MS` | `30000` | — | Bounds every HTTP call to the Sprites API. Long-running commands (package installs, clones) set their own per-call timeouts. Boot refuses a non-positive value |
| `SANDBOX_PROVIDER` | `sprites` | — | Which backend newly-created sandboxes run on: `sprites`, `e2b`, `daytona`, or `runner`. A hosted provider is enabled by the presence of its credential; boot refuses an explicit default whose credential is missing. Existing sandboxes stay on the provider they were created on |
| `SANDBOX_RUNNERS_ENABLED` | `true` | — | [Self-hosted runners](integrations/runners.md) need no credential; `false` hides the `runner` provider and refuses `fountain runner` connections |
| `E2B_API_KEY` | — | for the `e2b` provider | [E2B](https://e2b.dev) API key. Its presence enables the provider |
| `E2B_BASE_URL` | `https://api.e2b.app` | — | Repoints the E2B control plane |
| `E2B_TEMPLATE` | `base` | — | Template new E2B sandboxes are created from. The stock `base` template lacks the agent CLIs — build one from `images/e2b/` for real use |
| `E2B_USER` | `sprite` | — | In-guest user envd runs commands as. `images/e2b/` templates create `sprite`; set to `user` when pointing at the stock `base` template |
| `DAYTONA_API_KEY` | — | for the `daytona` provider | [Daytona](https://daytona.io) API key. Its presence enables the provider |
| `DAYTONA_API_URL` | `https://app.daytona.io/api` | — | Repoints the Daytona API (self-hosted Daytona) |
| `DAYTONA_SNAPSHOT` | org default | — | Snapshot (image) new Daytona sandboxes are created from; must be registered with the organization. The default image lacks the agent CLIs — build one from `images/daytona/` for real use |
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | — | No turn activity for this long and the sandbox is reclaimed — the conversation stays [resumable](self-hosting.md#sandbox-lifetime). `0` disables the bound; boot refuses anything that is not a non-negative integer |
| `SANDBOX_MAX_LIFETIME_HOURS` | `24` | — | Absolute sandbox age ceiling, regardless of activity. Same `0`-disables and boot-refusal rules |
| `LOG_OUTPUT_BUDGET_MB` | `50` | — | Durable log volume per conversation. Once a conversation has persisted this much sandbox output, one truncation marker is written and further output is discarded (retention bounds age; this bounds rate). Same `0`-disables and boot-refusal rules |

## Registration and accounts

| Variable | Default | Required | Effect |
|---|---|---|---|
| `REGISTRATION_ENABLED` | `true` | — | `false` closes signup entirely. An open instance on the public internet will be found |
| `REGISTRATION_ALLOWED_EMAIL_DOMAINS` | any | — | Comma-separated list; signups outside these domains are refused. Empty means no restriction |
| `UNVERIFIED_PRUNE_AFTER_DAYS` | `30` | — | Accounts that never verified their email are deleted after this many days — they can sign in but reach nothing, so they are rows, not users. `0` disables the sweep |
| `UNVERIFIED_PRUNE_EXEMPT` | — | — | Comma-separated email substrings never pruned (operator or test accounts that deliberately stay unverified) |
| `FIRST_USER_ADMIN` | `false` | — | `true`: while the instance has no admin, the first account to become verified is promoted to admin, audit-recorded (ADR 0011). Leave off on a multi-tenant deployment — it hands admin to whoever verifies first |

## Email

Production **refuses to boot** unless exactly one of the three delivery
options is configured — a silently discarded verification email dead-ends
signup with no visible error. See [Email](self-hosting.md#email).

| Variable | Default | Required | Effect |
|---|---|---|---|
| `RESEND_API_KEY` | — | one of three | Delivery via Resend |
| `SMTP_HOST` | — | one of three | Delivery via any SMTP server |
| `SMTP_PORT` | `587` | — | SMTP port |
| `SMTP_USERNAME` | — | — | Omit entirely for an unauthenticated relay |
| `SMTP_PASSWORD` | — | — | |
| `SMTP_TLS` | `always` | — | STARTTLS by default; `never` for a relay on a trusted network that does not offer it |
| `EMAIL_DELIVERY` | — | one of three | `none` deliberately disables email. Accounts then self-verify at registration (ADR 0011), but password-reset email cannot be delivered, so a forgotten password is unrecoverable in this mode |
| `EMAIL_FROM` | — | when mail is on | The From address. Required whenever a real delivery provider is configured — a prod instance refuses to boot without it, since mail from an unverified domain is rejected anyway. Unused under `EMAIL_DELIVERY=none` |
| `SUPPORT_EMAIL` | — | — | Where "contact support" in account emails (suspension, deletion) points, and where `POST /api/support/reports` reports are mailed. Unset, the copy names no address and reports are not mailed |
| `SUPPORT_GITHUB_REPO` | — | — | `owner/repo`: each support report also becomes a GitHub issue there (labels `support` + category). Needs `SUPPORT_GITHUB_TOKEN` |
| `SUPPORT_GITHUB_TOKEN` | — | — | A token with `issues:write` on `SUPPORT_GITHUB_REPO` |

## Authentication

| Variable | Default | Required | Effect |
|---|---|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | — | — | Enables the GitHub sign-in button; unset, the button is hidden and email + password auth still works |
| `GITHUB_OAUTH_CLIENT_SECRET` | — | — | |

## Billing

| Variable | Default | Required | Effect |
|---|---|---|---|
| `BILLING_ENABLED` | `false` | — | The subscription gate. Off by default — on a self-hosted instance it is a lock with no key. Set `true` only if you run Fountain commercially with Stripe configured |
| `STRIPE_SECRET_KEY` | — | for billing | Stripe API key |
| `STRIPE_WEBHOOK_SECRET` | — | for billing | Verifies `POST /api/stripe/webhook` signatures |
| `STRIPE_PRICE_ID` | — | for checkout | The subscription price surfaced by Checkout. Unset with billing enabled, signups get a purely local 14-day trial and a logged warning |
| `STRIPE_PRICE_MONTHLY_CENTS` | — | no | Monthly price in cents (e.g. `2900`), display-only: feeds the admin billing overview's MRR tile. Unset, the tile shows a placeholder instead of a fabricated number |

## Legal pages

The identity rendered on `/terms` and `/privacy` — the operator's, not the Fountain project's. Set all four or none: a partial set refuses to boot. With none set, the pages return 404 and their links disappear from signup and the footer — unless billing is enabled, in which case the pages stay up with loud `{{...}}` placeholders until you configure them (an instance charging money should publish terms).

| Variable | Default | Required | Effect |
|---|---|---|---|
| `LEGAL_ENTITY` | — | no | The legal entity operating this instance (e.g. `Example Corp Inc.`) |
| `LEGAL_CONTACT_EMAIL` | — | no | Contact address shown on both pages |
| `LEGAL_JURISDICTION` | — | no | Governing law / venue (e.g. `the State of Delaware, USA`) |
| `LEGAL_EFFECTIVE_DATE` | — | no | The "Last updated" date on both pages |

## Proxies and origins

| Variable | Default | Required | Effect |
|---|---|---|---|
| `TRUSTED_PROXIES` | — | behind a proxy | Comma-separated CIDRs stepped over when resolving the client IP from `X-Forwarded-For`. Without it, per-IP rate limits collapse into one bucket keyed on the proxy; over-broad, it lets a client spoof past rate limiting |
| `CHECK_ORIGIN_EXTRA` | — | — | Comma-separated extra origins allowed to open a LiveView websocket. Your own host is always included |
| `OAUTH_CLIENTS` | — | — | JSON array of `{id, name, redirect_uris}` — the browser apps allowed to "Sign in with Fountain" (OAuth code + PKCE, public clients; `decisions/0021`). Redirect URIs match exactly. Unset means none |
| `API_CORS_ORIGINS` | — | — | Comma-separated browser origins (or `*`) allowed to call `/api` with a bearer key from another site — what a standalone client such as the team app needs. Off when unset; cookies never cross origins regardless |

## Clustering

Only needed for more than one replica — see
[Clustering](architecture.md#clustering) for what breaks without it.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `CLUSTER_DNS_QUERY` | — | multi-replica | DNS name polled for peer discovery (a headless service in Kubernetes). Empty or unset, clustering is off |
| `RELEASE_NAME` | set by the release | — | Node basename used in peer discovery; must match what each node registered as. The release tooling sets it — override only if you know why |
| `DNS_CLUSTER_QUERY` | — | — | A second, separate discovery mechanism (Phoenix's `DNSCluster`). Leave unset when using `CLUSTER_DNS_QUERY` |

## Observability

| Variable | Default | Required | Effect |
|---|---|---|---|
| `METRICS_PORT` | `9568` in prod, off elsewhere | — | The private Prometheus listener (`/metrics`, `/health`). `""` or `0` disables it. Keep it off the public internet |
| `SENTRY_DSN` | — | — | Error tracking. Unset, the SDK is inert and nothing leaves the instance. Accepts sentry.io or any Sentry-API-compatible endpoint (GlitchTip) |
| `SENTRY_ENVIRONMENT` | the build env | — | Environment tag on reported errors |
| `FOUNTAIN_BUILD_SHA` | set by the image build | — | Correlates errors and traces with deploys; also shown in the app footer |
| `OTEL_SERVICE_NAME` | `fountain` | — | Service name on exported traces |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `HONEYCOMB_ENDPOINT` | — | OTLP (HTTP/protobuf) trace export target |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | — | `key=val,key=val` headers on trace export |
| `HONEYCOMB_ENDPOINT` | `https://api.honeycomb.io` | — | Honeycomb shortcut for the endpoint above |
| `HONEYCOMB_API_KEY` | — | — | Honeycomb shortcut: adds the `x-honeycomb-team` header |

Trace export is configured only in production while serving, and is **off by
default**: spans are exported only when `OTEL_EXPORTER_OTLP_ENDPOINT`,
`HONEYCOMB_ENDPOINT` or `HONEYCOMB_API_KEY` is explicitly set. The OTel SDK
also honours its own standard variables, which take precedence — set
`OTEL_TRACES_EXPORTER=otlp` or `=none` to force export on or off regardless
of the above.

## Hosted Buzz agents

Fountain can host a [Buzz](https://github.com/block/buzz) agent's `buzz-acp`
harness (ADR 0020), so a Buzz agent keeps a body on its relay without a running
desktop. The harness binary is baked into the image for both amd64 and arm64;
these tune where it runs and how its ACP child reaches back. Operators rarely
set them — the defaults are correct for the packaged image.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `BUZZ_ACP_BASE_URL` | the loopback endpoint (`http://127.0.0.1:$PORT`) | — | Base URL the harness's ACP child (`fountain acp`) uses to reach this instance. Defaults to loopback so harness traffic never leaves the pod; override only to point the child at a different Fountain endpoint |
| `FOUNTAIN_CLI_PATH` | `/usr/local/bin/fountain` | — | Path to the `fountain` CLI the harness runs as its ACP child. The image bakes it at the default; override only for a non-standard layout |

Upstream publishes `buzz-acp` for amd64 only, so Fountain builds it for both
architectures from source and bakes it in (see `.github/workflows/buzz-acp-publish.yml`).
