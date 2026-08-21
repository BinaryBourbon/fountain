# Connect a database

This guide shows you how to point Fountain at a Postgres you manage, turn on
TLS verification, and move migrations out of boot into an explicit step.

## Before you start

Fountain needs Postgres 16 or newer. The compose file runs one for you, and
this guide is for replacing it with a managed database or running migrations
separately.

## Point it at your database

`DATABASE_URL` is the connection. The app runs its migrations at boot, so
upgrading is `docker compose pull && docker compose up -d`.

`DATABASE_SSL` defaults to on, and the compose file sets it to `false` because
a stock `postgres` image does not serve TLS. If you point Fountain at a managed
database, remove that line.

To verify the server certificate rather than merely encrypt to it:

```bash
DATABASE_SSL_VERIFY=true
# optional, otherwise the OS trust store is used
DATABASE_SSL_CA_FILE=/etc/ssl/certs/rds-ca.pem
```

## Running migrations in a Job

Migrating at boot is right for one replica and is not the only shape. Set
`MIGRATE_ON_BOOT=false` and the release starts without migrating. Run the
migration entrypoint yourself, once, before the new version serves.

```bash
bin/migrate     # in the image; equivalent to
                # bin/fountain_server eval 'Fountain.Release.migrate()'
```

`bin/migrate` ignores `MIGRATE_ON_BOOT`. It is the thing you run *to* migrate.
In Kubernetes that is a Job ordered before the rollout, and
[`deploy/k8s/README.md`](https://github.com/BinaryBourbon/fountain/blob/main/deploy/k8s/README.md)
has the manifest.

Three things are worth knowing before you turn it off.

- **Nothing verifies the Job ran.** A pod with the switch off boots happily
  against an un-migrated database and fails on the first query that needs the
  new column. Ordering the Job ahead of the rollout is your job, not the app's.
- **You do not need this to run several replicas.** Boot migrations are
  serialized by a Postgres advisory lock, taken before `schema_migrations` is
  touched, so even the first boot against an empty database does not race.
- **What it buys you** is migrations as an explicitly reviewable step, app pods
  that can run with a database role that cannot `ALTER`, and faster pod starts
  on scale-up.

## Verify it worked

```bash
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

A 503 here means this instance cannot reach its database.

## Related

- [Back up and restore](back-up-and-restore.md).
- [Upgrade an instance](upgrade.md).
- [Configuration reference](../../configuration.md), for every `DATABASE_*`
  variable.
