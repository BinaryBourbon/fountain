# Architecture

This page is the system view: what processes exist, what they talk to, and what
breaks when each dependency is down. For the domain objects — agents,
environments, vaults, conversations — see [The four primitives](primitives.md).

---

## The runtime shape

Fountain is **one OTP release**, `fountain_server`. Everything below runs
inside a single BEAM instance — there are no separate worker deployments or
sidecars, and scaling out means running more replicas of the same image.

| Piece | Job |
|---|---|
| **Phoenix endpoint** | The one public listener: the operator console, the REST API, and SSE streaming, all on the same port |
| **Conversation server** | One process per active conversation. Owns the sandbox: provisions it, spawns turns in it, streams output back, enforces lifecycle bounds. Holds the decrypted tenant key in memory for the duration. Registered cluster-wide, so exactly one exists per conversation no matter how many replicas run |
| **Rehydrator** | Runs once at boot. Finds conversations that were live before the restart and restarts their servers, which reattach to the still-running sprite — a deploy does not kill running work |
| **Oban** | Background jobs (billing syncs, lifecycle emails, account exports on the `exports` queue) and the cron schedule below |
| **Metrics listener** | A second, private HTTP listener on `METRICS_PORT` (default 9568 in production, disabled elsewhere) serving `/metrics` and `/health`. Deliberately separate from the public endpoint, so an ingress rule can never accidentally expose it |

Scheduled work, all times UTC:

| Schedule | Job | What it does |
|---|---|---|
| Hourly at :07 | Sandbox reaper | Reconciles sandbox rows against sprites.dev: frees rows stuck mid-provision, expires abandoned sandboxes, destroys sprites whose row is already terminal, reports untracked sprites |
| 04:23 daily | Retention pruner | Deletes rows past retention — log events and Stripe events after 90 days, audit events after 365, usage events after 400, revoked API keys after 30 |
| 05:41 daily | Unverified-account pruner | Deletes accounts that never verified their email, after 30 days, through the full deletion path (Stripe, sprites, audit) |

### Clustering

One replica needs none of this. With more than one, replicas must form an
Erlang cluster — `CLUSTER_DNS_QUERY` pointed at a headless service
([`k8s/` shows the wiring](self-hosting.md#kubernetes)):

- The conversation registry places each conversation server on exactly one
  node and finds it from any node.
- PubSub fans a conversation's events to whichever replica holds the viewer's
  websocket or SSE connection.

Two unclustered replicas are isolated islands: conversations spawn fine, but
streaming silently breaks for viewers connected to the other replica.
Scheduled jobs elect a single leader regardless of replica count, and the
boot-time rehydration sweep waits for cluster membership to stabilize and runs
on one node only.

---

## Where state lives

**Postgres is the only durable store.** Users, agent and environment configs,
encrypted secrets, conversations, turns, log output, the audit trail, the job
queue, uploaded images — all rows. Sprites are disposable by design: output is
persisted as it streams, so destroying a sandbox loses nothing that mattered.

What is *not* durable, deliberately:

- Per-node in-memory tables: rate-limit counters and the log-redaction
  registry. Rebuilt empty at boot.
- Per-conversation memory: the decrypted tenant key, inference credentials,
  and the sandbox's callback token live only in that conversation's process
  and die with it.

Consequence: a complete backup is **Postgres plus `MASTER_SECRETS_KEY`** —
nothing else holds state. The [secrets model](#the-secrets-model) below is why
the key is half of that sentence.

---

## Dependencies and failure domains

| Dependency | Needed for | When it is down |
|---|---|---|
| **Postgres** | Everything | `GET /health/ready` returns 503 and load balancers drain the instance; the app stays up and does not restart — restarting does not fix Postgres, so [the restart check deliberately checks nothing](self-hosting.md#health-endpoints). Recovery is automatic. A replica *booting* against a down database fails instead, because migrations run at boot |
| **sprites.dev** | Conversations | New provisions and wakes fail — bounded retries with backoff, then the conversation is marked `failed` (or left resumable, if it was a wake). Everything else keeps serving: sign-in, dashboards, agent/environment/vault management, past logs. Deliberately excluded from the readiness check — a third party's uptime does not belong on the serving path |
| **Stripe** | Billing — optional, `BILLING_ENABLED` | Checkout and the billing portal fail with a visible error; the billing page itself still renders from local state. Webhooks are redelivered by Stripe until acknowledged. Trial expiry is enforced against the local clock, so an outage delays revenue rather than opening the gate |
| **Mail** (Resend or SMTP) | Signup verification, password reset | Both dead-end while the provider is down. Escape hatch: `Fountain.Release.verify_email/1` — see [Email](self-hosting.md#email). (`EMAIL_DELIVERY=none` is different: accounts self-verify, ADR 0011) |
| **GitHub OAuth** | The OAuth login button — optional | Only that button. Email/password auth is unaffected |
| **Sentry** | Error reporting — optional | Inert without a DSN; nothing depends on it |
| **Object storage** | Database backups — ops layer | The application never touches object storage; it exists only in a deployment's backup pipeline |
| **Inference providers** | Turns | Credentials are per-user, stored by Fountain but consumed *inside* the sandbox. An Anthropic or OpenAI outage fails turns, not Fountain |

---

## The secrets model

Envelope encryption, two layers:

1. Each tenant has a **data encryption key** (DEK). Every environment and
   vault secret is encrypted with it, AES-256-GCM.
2. The DEK itself is stored **wrapped** by `MASTER_SECRETS_KEY` — an
   environment variable, never written to the database.

The blast radius follows from the layout:

- **A database backup cannot decrypt itself.** Restoring secrets requires the
  same `MASTER_SECRETS_KEY` the backup was written under —
  [keep it separate from the backups](self-hosting.md#back-up-master_secrets_key).
- Losing or changing the master key makes every stored secret unrecoverable.
  Nothing else is lost — accounts, configs and history are plain rows.
- An attacker with only database access holds ciphertext and wrapped keys, not
  values.

At spawn time, a conversation's server loads its tenant's DEK into memory,
decrypts environment then vault secrets (**vault wins on key collision**),
resolves `${VAR}` references in the agent's MCP config, registers every value
with the log redactor *before anything can log*, and hands the values to the
sandbox as process env plus a `chmod 600` env file. The DEK never leaves that
process and is discarded when it stops. The API is write-only throughout: a
stored value is never returned.

---

## A conversation's life

Progress is recorded as **stage events**. The stage names below are the exact
strings shown in the UI, the SSE stream and the log rows, each with a state of
`started`, `done`, `failed` or `interrupted`.

1. **Gates.** A prompt arrives — `POST /api/conversations`, or a client on it. In order:
   the agent must exist *and belong to you* (every query in the system is
   tenant-scoped); the vault must be on the agent's allowlist; the
   subscription gate, when billing is enabled (`402` otherwise); the
   concurrent-sandbox quota (default 5 per user).
2. **`provision`.** Sandbox and conversation rows are created (`pending`) and
   a conversation server starts. It creates the sprite, mounts skills, mints a
   scoped, expiring API key the sandbox uses to call back into Fountain,
   assembles the env, and writes it into the sprite. Then either
   **`checkpoint_restore`** — a warm start from an environment checkpoint,
   skipping the rest — or the cold pipeline: **`packages` → `network` →
   `clone` → `setup`**. The sandbox is now `ready`. Any failed step destroys
   the sprite and marks sandbox and conversation `failed`.
3. **`turn`.** The runtime (claude, codex, gemini, opencode) is spawned inside
   the sprite. Its output flows back to the server, is redacted, persisted as
   log events, and broadcast — the LiveView and the SSE endpoint
   (`GET /api/conversations/:id/stream`, resumable via `Last-Event-ID`) are
   both just subscribers to the same feed.
4. **Idle.** The turn exits and the conversation goes `idle`, sandbox still
   warm. A follow-up prompt starts the next turn immediately.
5. **`reattach`.** If the server is gone — a deploy, a node loss — but the
   sprite survived, the next prompt (or the boot-time rehydrator) reattaches:
   verify the sprite still exists, rewrite its env, pick a still-running
   turn's session back up where it left off. The runtime's session lives on
   the sprite's disk, so reattaching to the *same* sprite keeps the agent's
   memory. If the sprite is gone, the conversation re-provisions from step 2 —
   Fountain's transcript survives, the agent's session does not (#649).
6. **`sandbox`** — the lifetime bounds. Every server checks its
   [bounds](self-hosting.md#sandbox-lifetime) each minute, and they do
   different things: crossing the **idle timeout** *suspends* — the server
   stops, the sprite stays (it scales itself to zero) and the sandbox parks in
   `suspended`, to be woken with everything intact by the next prompt.
   Crossing the **max lifetime** *destroys* the sprite and marks the sandbox
   `terminated`; the conversation goes back to `idle`, resumable at the #649
   price. The hourly reaper applies the same split to anything a crashed
   server left behind.
7. **`terminate`.** An explicit `POST .../terminate` destroys the sprite and
   marks the conversation `terminated` — one of the two terminal states,
   alongside `failed`.

The two status vocabularies, side by side:

```
conversation:  pending -> running -> idle -> running ...     -> failed | terminated
sandbox:       pending -> starting -> ready <-> suspended    -> terminated | failed
```

A conversation outlives its sandboxes: `idle` with a `suspended` sandbox is
the normal resting state, not an error (and `idle` with a `terminated` one is
what a max-lifetime reclaim leaves behind).

---

## Where to look

The point of this page: given a symptom, predict the component. The action
level — what to run and what the output means — is [Operations](operations.md).

| Symptom | Look at |
|---|---|
| Conversation stuck or `failed` during startup | The stage events in its log view name the failing step. `packages`, `clone` and `setup` failures are usually the environment's own config; `provision` failing outright is sprites.dev or the sandbox quota |
| UI down, `GET /health/ready` returns 503 | Postgres |
| Container restarts in a loop at boot | Migrations cannot reach Postgres — boot fails before anything listens |
| Streaming dead for some viewers, fine for others, multiple replicas | Erlang clustering — `CLUSTER_DNS_QUERY` |
| Signups never complete | Mail delivery — see [Email](self-hosting.md#email) |
| `402 subscription_required` on a self-hosted instance | `BILLING_ENABLED` should be `false` |
| Sandbox suspends between prompts, work resumes on the next one | Working as designed — [lifecycle bounds](self-hosting.md#sandbox-lifetime) |
