# Sentry

**Optional, and inert until you opt in.** With no DSN set, the SDK is
configured but does nothing — no account, no events, nothing leaves your
instance.

## Provider side

Create a project (platform: Elixir) on [sentry.io](https://sentry.io) or any
Sentry-API-compatible endpoint — GlitchTip works, for a fully self-hosted
stack — and take its DSN.

## Env vars

| Variable | Default | Effect |
|---|---|---|
| `SENTRY_DSN` | — | Turns reporting on. Crashes — including ones that never touch a web request — are reported with stack traces, grouped, rate-limited to 20 events/minute |
| `SENTRY_ENVIRONMENT` | the build env | Environment tag on events |
| `FOUNTAIN_BUILD_SHA` | set by the image build (release images) or by the deployment (main-line images) | Correlates events with releases: "this started with `sha-…`" |

Reporting is deliberately conservative: `send_default_pii` is off, so
cookies, user IPs and request bodies are not attached — this app holds tenant
secrets, and nothing the SDK gathers on its own should ride along.

## Crons: alerting when a scheduled job stops running

Sentry Monitors (Crons) catch the failure mode Prometheus alerts often miss:
a backup job that silently stops being scheduled. The pattern Fountain's own
deployment uses for its nightly `pg_dump`, reusable for any scheduled job:

- After the job **verifiably succeeds** (upload confirmed, not merely
  attempted), ping the check-in URL derived from the DSN:

    ```
    curl -fsS -m 10 "https://<sentry-host>/api/<project-id>/cron/<monitor-slug>/<public-key>/?status=ok"
    ```

- The monitor is auto-created on the first check-in. Then set its schedule
  and a grace period in the Sentry UI — that arms the alert for *missed*
  runs, which is the point.
- Keep it best-effort: a Sentry outage must never fail a successful backup.

## Verify

Set the DSN, restart, and cause any error — it appears in the project within
seconds, tagged with environment and release. Unset it and nothing does.
