# Run a release task

This guide shows you how to run an operator action that touches data. Each one
of them uses the same pattern.

## The pattern

Compose:

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("you@example.com")'
```

Kubernetes:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.verify_email(\"you@example.com\")'"
```

`eval` starts the database connection and nothing else. It never starts the
app. So a task cannot compete with the live server for ports, for background
jobs, or for conversation processes.

`PHX_SERVER=false` says that out loud in a container that sets it `true`.
Include it, and the pattern is always safe to paste.

## The tasks

| Task | What it does |
|---|---|
| `Fountain.Release.verify_email("a@b.c")` | Marks an account's email verified, and sends nothing. It is the escape hatch for a mail provider that broke. Since ADR 0011, `EMAIL_DELIVERY=none` self-verifies at registration. |
| `Fountain.Release.promote_admin("a@b.c")` | Grants the admin role. The admin audit trail records it under a system actor. It is the manual alternative to `FIRST_USER_ADMIN=true` (ADR 0011). |
| `Fountain.Release.expire_legacy_trials(dry_run: true)` | Reports. Drop `dry_run` and it backfills the trial end dates on legacy `trialing` accounts that have none. |
| `Fountain.Release.migrate()` | Runs the migrations that are due, by hand. It is what `bin/migrate` runs. They already run at each boot, unless `MIGRATE_ON_BOOT=false`. In that case this, in a Job before the rollout, is how they run at all. That switch never skips it. |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Rolls migrations back to a version. It is a last resort. Read [Upgrade an instance](upgrade.md) first. |

## Warnings

Use `rollback/2` to reverse one migration that you understand. Do not attempt
to reverse a whole release's migrations on production data.

`expire_legacy_trials/1` changes account state. Run it with `dry_run: true`
first, and read the report.

## Related

- [Upgrade an instance](upgrade.md).
- [Start billing](billing.md), which is where `expire_legacy_trials/1` <!-- vale disable-line STE.IngForms -->
  matters.
- [Nobody can log in](../../troubleshooting/nobody-can-log-in.md), which is
  where `verify_email/1` matters.
