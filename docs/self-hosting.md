# Self-hosting

Running your own Fountain instance.

For a development environment on your own machine, see [Setup](setup.md) — that
is a different thing, and this page assumes you want an instance that stays up.

## What you need

| | |
|---|---|
| **Postgres 16+** | The compose file below runs one for you |
| **A Sprites token** | Fountain provisions sandboxes through [sprites.dev](https://sprites.dev). The app boots without one, but every conversation fails |
| **A mail provider** | Resend or any SMTP server. Optional — see [Email](#email) |

Sprites is currently the only sandbox backend, and it is a hosted service, so a
Fountain instance is not fully self-contained. `SPRITES_BASE_URL` repoints the
API endpoint if you have a compatible one; there is no bundled alternative.

## Quick start

```bash
git clone https://github.com/BinaryBourbon/fountain
cd fountain

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
# add your SPRITES_TOKEN to .env

docker compose up -d
```

Then open <http://localhost:4000> and register. With the default
`EMAIL_DELIVERY=none` nothing is sent, so verify your own account:

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("you@example.com")'
```

Sign in, and close registration so nobody else can join:

```bash
echo "REGISTRATION_ENABLED=false" >> .env
docker compose up -d
```

To make yourself an admin, set the role directly — there is no bootstrap flow
for the first admin yet:

```bash
docker compose exec postgres psql -U postgres -d fountain \
  -c "UPDATE users SET role = 'admin' WHERE email = 'you@example.com';"
```

## Versioning and upgrades

Fountain follows [SemVer](https://semver.org/), pre-1.0: a patch release
(`v0.3.0` → `v0.3.1`) is always safe to take; a minor release (`v0.3` → `v0.4`)
may include breaking changes, and calls them out under **Upgrade notes** in the
[changelog](changelog.md).

Each release publishes the server image to `ghcr.io/binarybourbon/fountain`
under two tags, alongside the tags that track development:

| Tag | Moves? | Use it for |
|---|---|---|
| `vX.Y.Z` | Never | Pinning a known version — the recommended default |
| `vX.Y` | To the newest patch in the line | Taking patches automatically without risking a breaking minor |
| `latest` | On every merge to `main` | Nothing you keep running — it moves under you |
| `sha-<commit>` | Never | Reproducing exactly what a given commit built |

Releases v0.2.1 and earlier predate image tagging and exist only as `sha-`
tags.

The compose file reads `FOUNTAIN_IMAGE_TAG` from `.env`, so pinning is one
line:

```bash
echo "FOUNTAIN_IMAGE_TAG=v0.3.0" >> .env
```

Upgrading is editing that value, then `docker compose pull && docker compose
up -d`. Migrations run automatically at boot — idempotently, under an advisory
lock — so rolling replicas do not race each other, and there are no manual
migration steps unless a release's upgrade notes say otherwise. Downgrading is
not supported once a newer version's migrations have run; restore from a
backup instead.

The CLI and the server are cut from the same tag, so matching versions are the
tested pairing.

## Back up `MASTER_SECRETS_KEY`

Every environment and vault secret is encrypted with a per-tenant key that is
itself wrapped with `MASTER_SECRETS_KEY`. **Lose it and every stored secret is
unrecoverable; change it and the same is true.** It is not stored in the
database, by design — so a database backup alone does not protect you.

Keep it somewhere separate from your database backups, and treat rotating it as
a migration rather than a config change.

## Database

The app runs its migrations at boot, so upgrading is `docker compose pull &&
docker compose up -d`.

`DATABASE_SSL` defaults to on and the compose file sets it to `false`, because a
stock `postgres` image does not serve TLS. If you point Fountain at a managed
database, remove that line. To verify the server certificate rather than merely
encrypt to it:

```bash
DATABASE_SSL_VERIFY=true
# optional, otherwise the OS trust store is used
DATABASE_SSL_CA_FILE=/etc/ssl/certs/rds-ca.pem
```

### Backups

Nothing here backs up your database. Fountain's own deployment uses a nightly
`pg_dump` to object storage; the mechanism is described in the
[operator runbook](https://github.com/BinaryBourbon/fountain/blob/main/apps/fountain/priv/help/runbook.md).
At minimum:

```bash
docker compose exec postgres pg_dump -U postgres -Fc fountain > fountain-$(date +%F).dump
```

Restore into a scratch database and check the row counts before you need it in
anger. A backup nobody has restored is a hypothesis.

## Email

Fountain refuses to start in production without a mail setting, because a
silently discarded verification email dead-ends signup with no visible error.
Pick one:

| Setting | Effect |
|---|---|
| `RESEND_API_KEY` | Delivery via Resend |
| `SMTP_HOST` (+ `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`) | Any SMTP server. Port defaults to 587 with STARTTLS; omit the username for an unauthenticated relay |
| `EMAIL_DELIVERY=none` | No email. Verify accounts with `Fountain.Release.verify_email/1` |

Password reset also needs working mail. With `EMAIL_DELIVERY=none` the only
route back into a locked-out account is the database.

## Sandbox lifetime

Sandboxes are reclaimed when they go idle or reach a maximum age, so an
abandoned conversation stops costing you:

| Setting | Default | |
|---|---|---|
| `SANDBOX_IDLE_TIMEOUT_MINUTES` | `60` | No turn activity for this long and the sandbox is torn down |
| `SANDBOX_MAX_LIFETIME_HOURS` | `24` | Absolute ceiling from creation, regardless of activity |

Set either to `0` to disable it. A value that is not a non-negative integer
refuses to boot rather than quietly disabling the bound.

Reclaiming ends the **sandbox**, not the conversation. The conversation stays
resumable — the next prompt provisions a fresh sandbox and the runtime resumes
the same session — so the cost of a bound being too aggressive is a
re-provisioning wait, not lost work.

## Billing

The compose file sets `BILLING_ENABLED=false`. The subscription gate exists for
the hosted service; on your own instance it is a lock with no key. Leave it off
unless you are running Fountain commercially and have configured Stripe.

## Putting it on the internet

The compose file publishes port 4000 with no TLS. Terminate TLS in front of it
with Caddy, nginx, or a tunnel, and then:

- set `PUBLIC_URL` to the external URL, scheme included — it builds verification
  links and is passed to every sandbox
- set `TRUSTED_PROXIES` to your proxy's address range, or per-IP rate limits will
  all collapse into one bucket keyed on the proxy
- close registration, or set `REGISTRATION_ALLOWED_EMAIL_DOMAINS`

An `https://` `PUBLIC_URL` also switches on HTTPS redirection, HSTS (one year,
including subdomains — not preloaded) and the `secure` flag on the session
cookie. All three are derived from the scheme rather than set separately,
because none of them can be on for an `http://` instance: a cookie marked
secure is never sent back, and the redirect would point at a port serving
nothing. If you terminate TLS in front of Fountain, make sure your proxy sets
`X-Forwarded-Proto` — the redirect uses it, and without it every request looks
like plain http and loops.

`CHECK_ORIGIN_EXTRA` adds origins allowed to open a LiveView websocket, as a
comma-separated list. Your own host is always included; add to this only for
something like a preview environment on a different domain.

Registration is open by default. An instance on the public internet with
registration open will be found.

## Observability

The app serves Prometheus metrics on port 9568, which the compose file does not
publish. Add a port mapping if you are scraping it, and keep it off the public
internet — it enumerates routes, request rates and database timings.

Logs go to stdout: `docker compose logs -f app`.

Error tracking is off unless you opt in: set `SENTRY_DSN` and crashes —
including the ones that never touch a web request — are reported with stack
traces, grouped, and correlated with releases. The endpoint can be sentry.io
or anything Sentry-API-compatible (GlitchTip, for a fully self-hosted stack).
Unset, nothing ever leaves your instance.

### Health endpoints

Two, because restarting a container and taking it out of a load balancer are
different decisions:

| | |
|---|---|
| `GET /health` | Always 200 while the app is running. Checks nothing. Point a **restart** check here — if it consulted the database, a Postgres blip would restart every container at once, which does not fix Postgres |
| `GET /health/ready` | 200 when this instance can serve, 503 when it cannot reach its database. Point **load balancer** and deploy gates here |

```bash
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

Both are public and unauthenticated, and report `ok`/`error` per check with no
further detail — a failing check does not describe your database to whoever
asked.

A healthy check takes about 2ms; an unreachable database takes a few seconds to
give up, so give the check a timeout above one second if your platform defaults
lower.

## Kubernetes

A portable baseline lives in
[`deploy/k8s/`](https://github.com/BinaryBourbon/fountain/tree/main/deploy/k8s)
— plain manifests applied with `kubectl apply -k`, no operators or CRDs
assumed. You bring a Postgres, an ingress controller, and the
`fountain-secrets` Secret; its README walks through the rest, and the probe
and scaling reasoning is commented inline in the manifests.

`k8s/` in this repository is a different thing: the maintainer's own cluster
(CNPG, Traefik, cert-manager, Infisical, Flux, Longhorn, personal hostnames).
It is worth reading — it shows the full Erlang-clustering wiring for running
more than one replica — and is not worth applying.

## Licence

Fountain is MIT licensed — running your own instance is explicitly fine,
including commercially.

## Known gaps

Being straight about what self-hosting does not yet include:

- **Sprites is a hosted dependency** — `SPRITES_BASE_URL` can repoint it, but
  there is no self-hostable sandbox backend to point it at.
- **No first-admin bootstrap**; the role is set in SQL.
