# Sentry

**Optional, and inert until you opt in.** With no DSN set, the SDK is
configured but does nothing. No account, no events, nothing leaves your
instance.

## At a glance

| | |
|---|---|
| Required | No |
| Provider | sentry.io, or anything Sentry-API-compatible such as GlitchTip |
| Env vars | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` |
| Rate limit | 20 events per minute |
| Without it | The SDK is inert and nothing leaves the instance |

## Provider side

Create a project (platform: Elixir) on [sentry.io](https://sentry.io) or any
Sentry-API-compatible endpoint, such as GlitchTip for a fully self-hosted
stack, and take its DSN.

## Env vars

| Variable | Default | Effect |
|---|---|---|
| `SENTRY_DSN` | — | Turns reporting on. Crashes, including ones that never touch a web request, are reported with stack traces, grouped, rate-limited to 20 events/minute |
| `SENTRY_ENVIRONMENT` | the build env | Environment tag on events |
| `FOUNTAIN_BUILD_SHA` | set by the image build (release images) or by the deployment (main-line images) | Correlates events with releases: "this started with `sha-…`" |

Reporting is deliberately conservative: `send_default_pii` is off, so
cookies, user IPs and request bodies are not attached, because this app holds tenant
secrets, and nothing the SDK gathers on its own should ride along.

## Crons: alerting when a scheduled job stops running

Sentry Monitors (Crons) catch the failure mode Prometheus alerts often miss:
a backup job that silently stops being scheduled. The pattern Fountain's own
deployment uses for its nightly `pg_dump` is reusable for any scheduled job.

- After the job **verifiably succeeds** (upload confirmed, not merely
  attempted), ping the check-in URL derived from the DSN.

    ```
    curl -fsS -m 10 "https://<sentry-host>/api/<project-id>/cron/<monitor-slug>/<public-key>/?status=ok"
    ```

- The monitor is auto-created on the first check-in. Then set its schedule
  and a grace period in the Sentry UI, which arms the alert for *missed*
  runs, which is the point.
- Keep it best-effort: a Sentry outage must never fail a successful backup.

## Verify

Set the DSN, restart, and cause any error. It appears in the project within
seconds, tagged with environment and release. Unset it and nothing does.

## Limits

**Nothing is sent until you set a DSN.** Unset, the SDK is inert rather than
buffering, so there is no backlog to flush when you turn it on.

**Tenant data is deliberately withheld.** Cookies, user IPs and request bodies
are not attached, because this app holds other people's secrets. That also
means a report carries less context than a stock Sentry integration would.

## Related

- [Wire up observability](../guides/operate/observability.md), including the
  alerting pack.
- [Back up and restore](../guides/operate/back-up-and-restore.md), which uses
  the Crons pattern below.
- [Services Fountain uses](index.md).
