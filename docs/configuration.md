# Configuration reference

Here is each environment variable that the server reads at runtime, in groups.
The server reads them at boot. To change one, restart the app.

This list is complete by construction. A test fails the build when
`config/runtime.exs` reads a variable that this page does not document. So the
reference cannot drift from the code without a sound.

A few variables **refuse to boot on an invalid value**. They fall back to no
default, and each row says so.

That is deliberate. A typo that quietly turned a bound or a key off would
otherwise surface as a bill or a breach. It would not surface as an error
message.

---

## Core

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_URL` | — | prod | The Postgres connection string. Boot fails without it. |
| `SECRET_KEY_BASE` | — | prod, to serve | Signs and encrypts the session cookies and the tokens. Generate one with `openssl rand -base64 48`. |
| `MASTER_SECRETS_KEY` | — | prod | Wraps each tenant's data-encryption key. Read [the secrets model](architecture.md#the-secrets-model). It is 32 bytes, url-safe base64, with no pad character: `openssl rand 32 \| base64 \| tr '+/' '-_' \| tr -d '='`. **Lose it and you lose each stored secret.** Boot refuses a malformed value. |
| `PUBLIC_URL` | — | prod | The base URL that the outside world sees, with the scheme. A prod instance refuses to boot without it, or without the deprecated `FOUNTAIN_DOMAIN`. The old `http://localhost:4000` fallback quietly put localhost links in each verification email. This variable builds each link that leaves the app, which is the verification and reset emails and `llms.txt`. Fountain passes it to each sandbox as `FOUNTAIN_BASE_URL`. An `https://` value also starts the HTTPS redirect, HSTS and the secure cookie flag, and Fountain derives all three from the scheme. |
| `PHX_HOST` | The host of `PUBLIC_URL`. | — | The bare host for the endpoint URL and for the LiveView origin check. Set it only when it differs from the host in `PUBLIC_URL`. |
| `FOUNTAIN_DOMAIN` | — | deprecated | The old combined variable. Fountain still honours it as a fallback for both of the two above. Prefer `PUBLIC_URL` and `PHX_HOST`. |
| `PHX_SERVER` | `true` in the shipped image. | — | A `1`, `true` or `yes` starts the web listener. A release task runs with `PHX_SERVER=false … eval '…'`. That boots the app, and binds no port. |
| `PORT` | `4000` | — | The HTTP port to listen on. |

## Database

| Variable | Default | Required | Effect |
|---|---|---|---|
| `DATABASE_SSL` | `true` | — | TLS to Postgres. Set `false` for a stock `postgres` container, which serves no TLS. |
| `DATABASE_SSL_VERIFY` | off. | — | Unset, the driver encrypts the connection and verifies no server certificate. `true` verifies it, against the OS trust store, unless you give a CA file. |
| `DATABASE_SSL_CA_FILE` | The OS trust store. | — | The CA bundle to use when `DATABASE_SSL_VERIFY=true`. |
| `POOL_SIZE` | `10` | — | The size of the database connection pool. |
| `MIGRATE_ON_BOOT` | `true` | — | Whether a release runs the migrations that are due before it serves. A `false`, and also `0` or `no`, makes the pod serve and no more. Use that for a deployment that runs the migrations once, in a Job. Read [migrations in a Job](guides/operate/database.md#run-migrations-in-a-job). `bin/migrate` always migrates, whatever you set here. **Nothing checks that the Job ran.** A pod that skips the migrations boots against a database nobody migrated. It then fails on the first query. |

## Sandboxes

| Variable | Default | Required | Effect |
|---|---|---|---|
| `SPRITES_TOKEN` | — | For conversations. | The platform token for [sprites.dev](https://sprites.dev). The app boots without it, and each conversation then fails. Never show it to a tenant, because it pays for each sandbox. |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | — | Repoints the sandbox API. Whatever you point it at must implement the same contract, and Fountain bundles no alternative. |
| `SPRITES_TIMEOUT_MS` | `30000` | — | Bounds each HTTP call to the Sprites API. A long command, such as a package install or a clone, sets its own timeout for that call. Boot refuses a value that is not positive. |
| `SANDBOX_PROVIDER` | `sprites` | — | Which backend a new sandbox runs on. One of `sprites`, `e2b`, `daytona` and `runner`. A hosted provider turns on when its credential is there. Boot refuses an explicit default whose credential is absent. A sandbox that already exists stays on the provider Fountain made it on. |
| `SANDBOX_RUNNERS_ENABLED` | `true` | — | A [self-hosted runner](integrations/runners.md) needs no credential. A `false` hides the `runner` provider, and refuses a `fountain runner` connection. |
| `E2B_API_KEY` | — | For the `e2b` provider. | The [E2B](https://e2b.dev) API key. Its presence turns the provider on. |
| `E2B_BASE_URL` | `https://api.e2b.app` | — | Repoints the E2B control plane. |
| `E2B_TEMPLATE` | `base` | — | The template that Fountain creates a new E2B sandbox from. The stock `base` template has no agent CLI, so build one from `images/e2b/` for real use. |
| `E2B_USER` | `sprite` | — | The in-guest user that envd runs a command as. An `images/e2b/` template creates `sprite`. Set it to `user` when you point at the stock `base` template. |
| `DAYTONA_API_KEY` | — | For the `daytona` provider. | The [Daytona](https://daytona.io) API key. Its presence turns the provider on. |
| `DAYTONA_API_URL` | `https://app.daytona.io/api` | — | Repoints the Daytona API, for a Daytona you host yourself. |
| `DAYTONA_SNAPSHOT` | The org default. | — | The snapshot, which is an image, that Fountain creates a new Daytona sandbox from. The organization must hold it. The default image has no agent CLI, so build one from `images/daytona/` for real use. |
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | — | No turn activity for this long, and Fountain reclaims the sandbox. The conversation stays [resumable](guides/operate/sandbox-lifetime.md). A `0` turns the bound off, and boot refuses whatever is not a non-negative integer. |
| `SANDBOX_MAX_LIFETIME_HOURS` | `24` | — | The absolute ceiling on a sandbox's age, whatever the activity. The same `0` rule and the same boot refusal apply. |
| `LOG_OUTPUT_BUDGET_MB` | `50` | — | The durable log volume for one conversation. Once a conversation has persisted this much sandbox output, Fountain writes one truncation marker and discards the rest. Retention bounds age, and this bounds rate. The same `0` rule and the same boot refusal apply. |

## Webhooks

| Variable | Default | Required | Effect |
|---|---|---|---|
| `WEBHOOKS_ENABLED` | `true` | — | A `false` stops every outbound [webhook](reference/webhooks.md). An endpoint stays saved and gets nothing. Use it on a deployment with no outbound egress. |
| `WEBHOOK_ALLOW_HTTP` | `false` | — | A `true` lets an endpoint URL use plain `http://`, for a receiver on your own network. It relaxes the scheme rule alone. Fountain refuses a loopback, link local or RFC1918 target either way, at every request. |

## Registration and accounts

| Variable | Default | Required | Effect |
|---|---|---|---|
| `REGISTRATION_ENABLED` | `true` | — | A `false` closes signup entirely. Somebody will find an open instance on the public internet. |
| `REGISTRATION_ALLOWED_EMAIL_DOMAINS` | any | — | A comma-separated list. Fountain refuses a signup outside these domains. Empty means no restriction. |
| `UNVERIFIED_PRUNE_AFTER_DAYS` | `30` | — | Fountain deletes an account that never verified its email after this many days. Such an account can sign in and reach nothing, so it is a row and not a user. A `0` turns the sweep off. |
| `UNVERIFIED_PRUNE_EXEMPT` | — | — | Comma-separated email substrings that the sweep never prunes. Use it for an operator or test account that stays unverified on purpose. |
| `FIRST_USER_ADMIN` | `false` | — | A `true` promotes the first account that becomes verified to admin, while the instance has no admin. The audit trail records it (ADR 0011). Leave it off on a multi-tenant deployment, because it hands admin to whoever verifies first. |

## Email

Production **refuses to boot** unless you configured exactly one of the three
delivery options. A verification email that Fountain throws away leaves signup
at a dead end, with no error to see. Read [Email](guides/operate/email.md).

| Variable | Default | Required | Effect |
|---|---|---|---|
| `RESEND_API_KEY` | — | One of three. | Resend delivers the mail. |
| `SMTP_HOST` | — | One of three. | Any SMTP server delivers the mail. |
| `SMTP_PORT` | `587` | — | The SMTP port. |
| `SMTP_USERNAME` | — | — | Omit it for a relay that wants no authentication. |
| `SMTP_PASSWORD` | — | — | |
| `SMTP_TLS` | `always` | — | STARTTLS by default. Use `never` for a relay on a trusted network that does not offer it. |
| `EMAIL_DELIVERY` | — | One of three. | A `none` turns email off, on purpose. An account then self-verifies at registration (ADR 0011). Nothing can deliver a password-reset email. So in this mode, a password that somebody forgets stays forgotten. |
| `EMAIL_FROM` | — | When mail is on. | The From address. A real delivery provider needs it. A prod instance refuses to boot without it, because a receiver rejects mail from a domain nobody verified anyway. `EMAIL_DELIVERY=none` uses it for nothing. |
| `SUPPORT_EMAIL` | — | — | Where "contact support" in an account email points. Those are the suspension and deletion emails. Fountain also mails a `POST /api/support/reports` report there. Unset, the copy names no address, and Fountain mails no report. |
| `SUPPORT_GITHUB_REPO` | — | — | An `owner/repo`. Each support report also becomes a GitHub issue there, with the labels `support` and the category. It needs `SUPPORT_GITHUB_TOKEN`. |
| `SUPPORT_GITHUB_TOKEN` | — | — | A token with `issues:write` on `SUPPORT_GITHUB_REPO`. |

## Authentication

| Variable | Default | Required | Effect |
|---|---|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | — | — | Turns the GitHub sign-in button on. Unset, Fountain hides the button, and email and password auth still works. |
| `GITHUB_OAUTH_CLIENT_SECRET` | — | — | |

## Payment

<!-- "billing" is a Technical Name here: BILLING_ENABLED is the flag, and the
     Elixir context carries the word. STE exempts a Technical Name from Rule
     3.4, and the linter has no vocabulary hook for that rule. -->
<!-- vale STE.IngForms = NO -->

| Variable | Default | Required | Effect |
|---|---|---|---|
| `BILLING_ENABLED` | `false` | — | The subscription gate. It is off by default, because on a self-hosted instance it is a lock with no key. Set `true` only if you run Fountain commercially, with Stripe configured. |
| `STRIPE_SECRET_KEY` | — | For billing. | The Stripe API key. |
| `STRIPE_WEBHOOK_SECRET` | — | For billing. | Verifies the signature on a `POST /api/stripe/webhook`. |
| `STRIPE_PRICE_ID` | — | No. | The flat price that the plans replaced. Accounts that bought it stay on the closed `legacy` plan. A new deployment does not need it. |
| `STRIPE_PRICE_ID_SOLO` | — | For the Solo plan. | The Stripe price for Solo. A plan with no price stays off the pricing table and off the plan picker. |
| `STRIPE_PRICE_ID_TEAM` | — | For the Team plan. | The Stripe price for Team. |
| `STRIPE_PRICE_ID_SCALE` | — | For the Scale plan. | The Stripe price for Scale. |
| `STRIPE_PRICE_ID_CONTACT` | — | No. | The Stripe price for one teammate contact. Fountain sets the quantity of that subscription item to the number of contacts the tenant holds. Leave it unset, and teammate contacts cost the tenant nothing. |
| `STRIPE_CONTACT_PRICE_CENTS` | `500` | No. | The monthly price of one teammate contact, in cents. It is for display alone. |
| `STRIPE_PRICE_MONTHLY_CENTS` | — | No. | The monthly price of the `legacy` plan, in cents, such as `2900`. It is for display alone, and it feeds the MRR tile in the admin overview. Unset, the tile shows a placeholder, and not a number somebody invented. |
| `DEFAULT_PLAN` | `solo` | No. | The plan for an account that has no plan of its own. On a self-hosted instance that is every account. Set `DEFAULT_PLAN=scale` to give every account the highest concurrency cap. |

<!-- vale STE.IngForms = YES -->

Each plan sets one number that Fountain enforces: how many sandboxes the tenant
can run at the same time. Run `mix fountain.verify_plans` after you set a price
variable. The task reads each price from Stripe and fails if the amount differs
from the catalog.

## Legal pages

These four variables carry the identity that `/terms` and `/privacy` render.
That is the operator's identity, and not the Fountain project's.

Set all four, or set none. A partial set refuses to boot. With none set, the
two pages return 404, and their links disappear from signup and the footer.

There is one exception. With payment turned on, the pages stay up and carry
loud `{{...}}` placeholders until you configure them. An instance that charges
money must publish terms.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `LEGAL_ENTITY` | — | No. | The legal entity that operates this instance, such as `Example Corp Inc.` |
| `LEGAL_CONTACT_EMAIL` | — | No. | The contact address that both pages show. |
| `LEGAL_JURISDICTION` | — | No. | The law and the venue that govern, such as `the State of Delaware, USA`. |
| `LEGAL_EFFECTIVE_DATE` | — | No. | The "Last updated" date on both pages. |

## Proxies and origins

| Variable | Default | Required | Effect |
|---|---|---|---|
| `TRUSTED_PROXIES` | — | Behind a proxy. | Comma-separated CIDRs that Fountain steps over as it resolves the client IP from `X-Forwarded-For`. Without it, the rate limit for each IP collapses into one bucket keyed on the proxy. Set it too broad, and a client can spoof its way past the rate limit. |
| `CHECK_ORIGIN_EXTRA` | — | — | Comma-separated extra origins that can open a LiveView websocket. Fountain always includes your own host. |
| `OAUTH_CLIENTS` | — | — | A JSON array of `{id, name, redirect_uris}`. It names the browser apps that can "Sign in with Fountain". That is OAuth code with PKCE, for a public client, and `decisions/0021` covers it. A redirect URI must match exactly. Unset means none. |
| `API_CORS_ORIGINS` | — | — | Comma-separated browser origins, or a `*`, that can call `/api` with a bearer key from another site. A standalone client such as the team app needs that. It is off when unset, and a cookie never crosses an origin either way. |
| `CONVERSATIONS_APP_URL` | `https://jakegaylor.com/fountain-conversations/` | — | Where the console sends a person to watch a conversation. The default is a static build that takes *your* Fountain's URL as input. So it works for a self-hosted server as soon as `API_CORS_ORIGINS` admits `https://jakegaylor.com`. Point it at your own copy instead, or set it to `""` to say this deployment has no such app. |
| `TEAM_APP_URL` | `https://jakegaylor.com/fountain-team/` | — | The same, for the team roster. |

## Clustering

You need this for more than one replica, and for nothing else. Read
[Clustering](architecture.md#clustering) for what breaks without it. <!-- vale disable-line STE.IngForms -->

| Variable | Default | Required | Effect |
|---|---|---|---|
| `CLUSTER_DNS_QUERY` | — | Multi-replica. | The DNS name that Fountain polls to discover a peer. In Kubernetes that is a headless service. Empty or unset, the cluster is off. |
| `RELEASE_NAME` | Set by the release. | — | The node basename that peer discovery uses. It must match what each node registered as. The release sets it, so override it only when you know why. |
| `DNS_CLUSTER_QUERY` | — | — | A second, separate discovery mechanism, which is Phoenix's `DNSCluster`. Leave it unset when you use `CLUSTER_DNS_QUERY`. |

## Observability

| Variable | Default | Required | Effect |
|---|---|---|---|
| `METRICS_PORT` | `9568` in prod, off elsewhere. | — | The private Prometheus listener, which serves `/metrics` and `/health`. A `""` or a `0` turns it off. Keep it off the public internet. |
| `SENTRY_DSN` | — | — | Turns error reports on. Unset, the SDK is inert and nothing leaves the instance. It accepts sentry.io, or any endpoint that speaks the Sentry API, such as GlitchTip. |
| `SENTRY_ENVIRONMENT` | The build env. | — | The environment tag on a reported error. |
| `FOUNTAIN_BUILD_SHA` | Set by the image build for a release image, or by the deployment for a main-line image. | — | Matches an error and a trace to a deploy. The app footer shows it too. |
| `OTEL_SERVICE_NAME` | `fountain` | — | The service name on an exported trace. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `HONEYCOMB_ENDPOINT` | — | The OTLP target for a trace export, over HTTP with protobuf. |
| `OTEL_EXPORTER_OTLP_HEADERS` | — | — | The `key=val,key=val` headers on a trace export. |
| `HONEYCOMB_ENDPOINT` | `https://api.honeycomb.io` | — | The Honeycomb shortcut for the endpoint above. |
| `HONEYCOMB_API_KEY` | — | — | The Honeycomb shortcut that adds the `x-honeycomb-team` header. |

Fountain configures a trace export in production, while it serves, and nowhere
else. It is **off by default**. It exports a span only when you explicitly set
`OTEL_EXPORTER_OTLP_ENDPOINT`, `HONEYCOMB_ENDPOINT` or `HONEYCOMB_API_KEY`.

The OTel SDK also honours its own standard variables, and those win. Set
`OTEL_TRACES_EXPORTER=otlp` or `=none` to force the export on or off, whatever
the table above says.

## Hosted Buzz agents

Fountain can host the `buzz-acp` harness for a
[Buzz](https://github.com/block/buzz) agent (ADR 0020). A Buzz agent then
keeps a body on its relay, with no desktop up.

The image bakes the harness binary in, for both amd64 and arm64. These two
variables tune where it runs, and how its ACP child reaches back. An operator
rarely sets either one, because the defaults are correct for the packaged
image.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `BUZZ_ACP_BASE_URL` | The loopback endpoint, `http://127.0.0.1:$PORT`. | — | The base URL that the harness's ACP child, `fountain acp`, uses to reach this instance. It defaults to the loopback, so harness traffic never leaves the pod. Override it only to point the child at a different Fountain endpoint. |
| `FOUNTAIN_CLI_PATH` | `/usr/local/bin/fountain` | — | The path to the `fountain` CLI that the harness runs as its ACP child. The image bakes it at the default, so override it only for a layout that is not standard. |

Upstream publishes `buzz-acp` for amd64 alone. So Fountain builds it for both
architectures from source, and bakes it in. Read
`.github/workflows/buzz-acp-publish.yml`.

## Feature flags

PostHog evaluates a per-user flag, `Fountain.FeatureFlags`, when you set a
project key. Fountain caches an answer for one minute for each user.

When PostHog is unreachable, Fountain reuses the last answer it gave. With no
answer at all, each flag reads off, so an outage never turns a feature on.
Without PostHog you can force a flag on for each user.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `POSTHOG_PROJECT_API_KEY` | — | — | The PostHog *project* API key. That is the public `phc_…` token, and not a personal key. Unset, Fountain looks up no flag remotely. |
| `POSTHOG_HOST` | `https://us.i.posthog.com` | — | The PostHog ingestion host. Use `https://eu.i.posthog.com` for EU Cloud, or an instance you host yourself. |
| `FEATURE_FLAGS_ON` | — | — | Comma-separated flag keys, forced on for each user, such as `team_comms`. It wins over PostHog. |

## Product analytics

The same project key sends product events to PostHog. Fountain captures them
on the server. There is no analytics script in the browser, and the console
loads no third-party code.

Set no key and Fountain sends nothing. Set a key and the events go to your own
PostHog project.

Fountain captures an event at three points in the code. Each point is a
function that the operation must call, so Fountain captures a new action
without a new call site.

- Every audited change, under the name of its audit action. `agent.created`
  and `vault.secret.write` are examples.
- Every usage event that the meter records, with a `usage.` prefix.
  `usage.turn_started` is an example.
- The end of a conversation turn, as `conversation.turn.done`,
  `conversation.turn.failed` or `conversation.turn.interrupted`.

Two kinds of audited change stay out of PostHog. The audit trail keeps both.

- The request log. Each API write leaves a second audit row named after the
  request line, such as `POST /api/agents/<id>`. The name holds a resource id,
  so PostHog would make a new event type for each resource. The first row
  already says what changed.
- An API key that Fountain issued to itself. A sandbox and a Buzz harness each
  get a key, and an OAuth token is a key. These were 70 percent of the trail in
  one day. A key that a person makes in the console, or through the API, is
  kept.

Fountain also captures `$pageview` for each console page, `$identify` when the
shape of an account changes, and `$feature_flag_called` when it reads a flag.
Each event carries the flags that Fountain already knows for that person, as
`$feature/<key>`.

Fountain sends no secret value, no environment variable value, no prompt and
no agent output. An event holds the name of the action, the type of the
resource, and counts or sizes.

Delivery is best-effort. Events go to a queue and leave in batches. Fountain
drops them if the queue is full or if PostHog answers with an error, and it
counts each drop on the `fountain.analytics.dropped` telemetry event. An
analytics failure cannot fail the operation it measures.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `POSTHOG_CAPTURE` | `true` | — | Set it to `false` to stop product events. Flag evaluation continues. |
| `POSTHOG_PERSON_PII` | `true` | — | Set it to `false` to keep the account email out of PostHog. The person is then known by user id alone. |
| `POSTHOG_INSTANCE` | `PHX_HOST` | — | The name of this deployment. Each event is a member of this PostHog group, so two deployments that report to one project stay apart. |

## Teammate email and phone

Behind the `team_comms` flag, you can give a teammate an email address, from
[AgentMail](https://agentmail.to), and a phone number, from
[AgentPhone](https://agentphone.ai). The teammate then gets MCP tools to send
and read on both.

Fountain holds the provider keys and serves the tools itself, so a key never
enters a sandbox. With either key unset, the feature reports itself
unavailable, even where the flag is on.

| Variable | Default | Required | Effect |
|---|---|---|---|
| `AGENTMAIL_API_KEY` | — | — | The AgentMail API key. Fountain creates a teammate inbox under it. |
| `AGENTMAIL_BASE_URL` | `https://api.agentmail.to` | — | The AgentMail API host. Use `https://api.agentmail.eu` for the EU region. |
| `AGENTMAIL_DOMAIN` | — | — | A custom domain that you verified, for a teammate address. Unset, Fountain uses AgentMail's shared domain. |
| `AGENTPHONE_API_KEY` | — | — | The AgentPhone API key. Fountain provisions a teammate number under it. |
| `AGENTPHONE_BASE_URL` | `https://api.agentphone.ai` | — | The AgentPhone API host. |
| `AGENTPHONE_WEBHOOK_SECRET` | — | — | The secret that AgentPhone returned when somebody pointed the account's master webhook at `POST /api/webhooks/agentphone` on this instance. It verifies an inbound delivery. A text to a teammate's `prompt_from_number` then becomes a prompt in its conversation. Unset, the endpoint answers 503 and processes nothing inbound. |
