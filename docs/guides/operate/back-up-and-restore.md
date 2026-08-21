# Back up and restore

This guide shows you how to take backups, prove they work, and restore one for
real.

A backup here is two things. A `pg_dump` of Postgres **and the
`MASTER_SECRETS_KEY` it was written under**. The key wraps every tenant's
encryption key, so a dump restored without it has secrets that nothing will
ever decrypt. Treat "which key was live when this was taken" as part of a
backup's identity.

## Back up `MASTER_SECRETS_KEY`

Every environment and vault secret is encrypted with a per-tenant key that is
itself wrapped with `MASTER_SECRETS_KEY`. **Lose it and every stored secret is
unrecoverable. Change it and the same is true.**

It is not stored in the database, by design, so a database backup alone does
not protect you.

Keep it somewhere separate from your database backups, and treat rotating it as
a migration rather than a config change.

## Take backups

**Compose.** The bundled service, off unless you opt in.

```bash
docker compose --profile backup up -d
```

Dumps land in the `backup_data` volume and are pruned after
`BACKUP_RETENTION_DAYS` (default 14). `BACKUP_INTERVAL_SECONDS` sets the
cadence.

**That volume is on the same host as the database.** It protects against bad
migrations and fat fingers, not a dead machine. Copy dumps off-host on a
schedule.

**Kubernetes.** `deploy/k8s/backup-cronjob.yaml` is the same discipline against
any S3-compatible bucket. Dump, size-check, upload, verify, then prune. It is
commented out of the kustomization until you create its secret, and setup is at
the top of the file.

## Run the restore drill

A backup nobody has restored is a hypothesis. Periodically, and always before
an upgrade, restore the newest dump into a scratch database and look at it.

Compose:

```bash
docker compose --profile backup exec backup ls -lh /backups
docker compose exec postgres createdb -U postgres fountain_drill
docker compose --profile backup exec backup \
  pg_restore --no-owner -d "dbname=fountain_drill" /backups/fountain-<ts>.dump

# Does it hold what production holds?
docker compose exec postgres psql -U postgres -d fountain_drill -c \
  "SELECT (SELECT count(*) FROM users) AS users,
          (SELECT count(*) FROM conversations) AS conversations,
          (SELECT max(inserted_at) FROM audit_events) AS newest_audit_row"

docker compose exec postgres dropdb -U postgres fountain_drill
```

Kubernetes. Fetch the dump from the bucket and do the same against a scratch
database on your Postgres:

```bash
aws s3 cp s3://<bucket>/pg_dump/fountain-<ts>.dump .
createdb -h <host> -U <user> fountain_drill
pg_restore --no-owner -h <host> -U <user> -d fountain_drill fountain-<ts>.dump
```

The drill passes when the counts look like production and the newest rows are
from the night of the dump. It does not pass merely because `pg_restore` exited
zero.

## Restore for real

Stop the app first so nothing writes mid-restore (`docker compose stop app`, or
scale the deployment to zero), then replace the live database and start the app
again.

```bash
pg_restore --clean --if-exists --no-owner -d "$DATABASE_URL" fountain-<ts>.dump
```

Two rules decide whether this works.

- The restored data decrypts only under the `MASTER_SECRETS_KEY` that was live
  when the dump was taken. If you rotated the key since, you need the old one.
- If the restore crosses an upgrade boundary, run the image version that
  matches the dump. See [Upgrade an instance](upgrade.md).

## Know the job still runs

A backup job that quietly stops is the classic way backups rot.

The Kubernetes CronJob has the
[Sentry Crons check-in](../../integrations/sentry.md#crons-alerting-when-a-scheduled-job-stops-running)
built in. Set `SENTRY_DSN` and arm the monitor's schedule.

On compose, check the service's log line dates.

```bash
docker compose --profile backup logs backup | tail -5
```

## Related

- [Upgrade an instance](upgrade.md), the moment a backup earns its keep.
- [Connect a database](database.md).
- [Observability](observability.md), for the staleness alert on the backup job.
