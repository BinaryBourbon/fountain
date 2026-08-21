# Upgrade an instance

This guide shows you how to move an instance to a newer Fountain release, and
what to do when an upgrade goes wrong.

## Before you start

Take a backup. An upgrade is the one moment where the supported path back
depends on having one. See [Back up and restore](back-up-and-restore.md).

Read **Upgrade notes** in the [changelog](../../changelog.md) before a minor
bump.

## How versions work

Fountain follows [SemVer](https://semver.org/), pre-1.0. A patch release
(`v0.3.0` to `v0.3.1`) is always safe to take. A minor release (`v0.3` to
`v0.4`) may include breaking changes, and calls them out under **Upgrade
notes** in the changelog.

Each release publishes the server image to `ghcr.io/binarybourbon/fountain`
under two tags, alongside the tags that track development.

| Tag | Moves? | Use it for |
|---|---|---|
| `vX.Y.Z` | Never | Pinning a known version, the recommended default |
| `vX.Y` | To the newest patch in the line | Taking patches automatically without risking a breaking minor |
| `latest` | On every merge to `main` | Nothing you keep running, because it moves under you |
| `sha-<commit>` | Never | Reproducing exactly what a given commit built |

Releases v0.2.1 and earlier predate image tagging and exist only as `sha-`
tags.

## Take a new version

The compose file reads `FOUNTAIN_IMAGE_TAG` from `.env`, and
`.env.compose.example` ships it set to a pinned release, so a fresh install is
pinned by construction. Even with the variable unset, the compose file falls
back to a pinned release rather than `latest`.

Upgrading is editing that value, then pulling.

```bash
docker compose pull && docker compose up -d
```

Migrations run automatically at boot, idempotently, serialized by a Postgres
advisory lock. Rolling replicas do not race each other, and there are no manual
migration steps unless a release's upgrade notes say otherwise. A migration
that builds an index concurrently opts out of that lock by design, and such
migrations are written to be safe to re-run.

If you have moved migrations into a Job with `MIGRATE_ON_BOOT=false`, running
the Job is the upgrade step. See
[Running migrations in a Job](database.md#running-migrations-in-a-job).

## Match the CLI to the server

The CLI and the server are cut from the same tag, so matching versions are the
tested pairing.

The CLI's built-in default `base_url` is the hosted instance
(`https://fountain.inevitable.fyi`), not yours. Point it at your instance
before exporting an API key, otherwise the first unconfigured command sends
that key to the hosted domain.

```bash
FOUNTAIN_BASE_URL=https://your-fountain.example.com fountain auth login
```

`auth login` records the URL in the saved profile, so this is a one-time step.

## Watch a deploy land

```bash
kubectl rollout status deployment/fountain -n fountain   # k8s
docker compose logs -f app                               # compose
```

A rollout that never completes is usually the startup probe failing, meaning
migrations that cannot finish, or a readiness probe failing against a database
problem that predates the deploy. See
[Pods restarting or not ready](../../troubleshooting/pods-restarting.md).

## When an upgrade goes wrong

The rules, in order of preference.

1. **Roll forward.** Pin `vX.Y.Z` tags, read **Upgrade notes** before a minor
   bump, and fix forward when something breaks.
2. **Downgrading is not supported once a newer version's migrations have
   run.** The supported path back is restoring the pre-upgrade database backup
   and running the previous image, accepting the loss of writes since the
   backup. This is why a backup taken before every upgrade is cheap insurance.
3. `Fountain.Release.rollback/2` exists for surgically reversing a migration
   you understand. Reversing an arbitrary release's migrations is not something
   to attempt on production data.

If a restore crosses an upgrade boundary, run the image version that matches
the dump.

## Related

- [Back up and restore](back-up-and-restore.md).
- [Run a release task](run-a-release-task.md), for `rollback/2` and `migrate/0`.
- [Changelog](../../changelog.md).
