# Run a release task

This guide shows you how to run an operator action that touches data. Every one
of them goes through the same invocation pattern.

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

`eval` starts only the database connection, never the app, so a task cannot
compete with the running server for ports, background jobs, or conversation
processes. `PHX_SERVER=false` makes that explicit in an environment where the
container sets it `true`. Include it and the pattern is always safe to paste.

## The tasks

| Task | What it does |
|---|---|
| `Fountain.Release.verify_email("a@b.c")` | Mark an account's email verified without sending anything. The escape hatch for a broken mail provider. `EMAIL_DELIVERY=none` self-verifies at registration since ADR 0011 |
| `Fountain.Release.promote_admin("a@b.c")` | Grant the admin role, recorded in the admin audit trail with a system actor. The manual alternative to `FIRST_USER_ADMIN=true` (ADR 0011) |
| `Fountain.Release.expire_legacy_trials(dry_run: true)` | Report, then without `dry_run` backfill, trial end dates on legacy `trialing` accounts that have none |
| `Fountain.Release.migrate()` | Run pending migrations by hand, which is what `bin/migrate` runs. They already run at every boot unless `MIGRATE_ON_BOOT=false`, in which case this, in a Job before the rollout, is how they run at all. Never skipped by that switch |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Roll migrations back to a version. Last resort, and read [Upgrade an instance](upgrade.md) before reaching for it |

## Warnings

`rollback/2` is for surgically reversing a migration you understand. Reversing
an arbitrary release's migrations is not something to attempt on production
data.

`expire_legacy_trials/1` changes account state. Run it with `dry_run: true`
first and read the report.

## Related

- [Upgrade an instance](upgrade.md).
- [Start billing](billing.md), which is where `expire_legacy_trials/1`
  matters.
- [Nobody can log in](../../troubleshooting/nobody-can-log-in.md), which is
  where `verify_email/1` matters.
