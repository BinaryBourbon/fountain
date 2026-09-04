# Upgrade an instance

This guide shows you how to move an instance to a newer Fountain release, and
what to do when an upgrade goes wrong.

## Before you start

Take a backup. An upgrade is the one moment where the supported path back
needs one. Read [Back up and restore](back-up-and-restore.md).

Read **Upgrade notes** in the [changelog](../../changelog.md) before a minor
bump.

## How versions work

Fountain follows [SemVer](https://semver.org/), before 1.0. A patch release,
`v0.3.0` to `v0.3.1`, is always safe to take. A minor release, `v0.3` to
`v0.4`, can break something. The changelog calls each break out under
**Upgrade notes**.

Each release publishes the server image to `ghcr.io/binarybourbon/fountain`
under two tags, next to the tags that track development.

| Tag | Moves? | Use it for |
|---|---|---|
| `vX.Y.Z` | Never. | To pin a known version. This is the default we suggest. |
| `vX.Y` | To the newest patch in the line. | To take patches on their own, with no risk of a minor that breaks something. |
| `latest` | On each merge to `main`. | Nothing you keep in production, because it moves under you. |
| `sha-<commit>` | Never. | To reproduce exactly what one commit built. |

## Two distributions

Each tag above names the **bundled** image: the server plus the first-party
extensions, which is what this project has always published. Each release also
publishes the same version with a `-core` suffix.

| Tag | Contains |
|---|---|
| `vX.Y.Z` and `vX.Y` | The server, the Buzz extension and the support extension, plus the `buzz-acp` and `buzz` executables the Buzz extension runs. |
| `vX.Y.Z-core` and `vX.Y-core` | The server. No extension, no extension route, no extension migration and no extension executable. |

Use the bundled image unless you know you want the other one. The hosted
deployment runs it, and we triage a bug report against it.

The core image is smaller and has less surface to attack. It is also what to
build an extension of your own against. The cost: hosted Buzz agents
(`/api/buzz/agents` and the Nostr harness) and the problem-report endpoint
answer `404`, because the code that serves them is not installed.

To move between them, pull the other tag and restart. Extension tables stay in
the database. A core image does not create them. It also does not drop the ones
a bundled image made, so a move back finds your rows where you left them.

Releases v0.2.1 and earlier are older than the image tags. They exist as
`sha-` tags alone.

## Take a new version

The compose file reads `FOUNTAIN_IMAGE_TAG` from `.env`, and
`.env.compose.example` ships it set to a pinned release. A fresh install is
therefore pinned by construction. Leave the variable unset and the compose
file still falls back to a pinned release, and not to `latest`.

To upgrade, edit that value, then pull.

```bash
docker compose pull && docker compose up -d
```

Migrations run on their own at boot. They are idempotent, and a Postgres
advisory lock serializes them. Replicas that roll do not race each other. You
run no manual migration step, unless a release's upgrade notes say to.

A migration that builds an index concurrently opts out of that lock by design.
Fountain writes such a migration so that a second run is safe.

Did you move migrations into a Job with `MIGRATE_ON_BOOT=false`? Then the Job
is the upgrade step. Read
[Run migrations in a Job](database.md#run-migrations-in-a-job).

## Match the CLI to the server

The CLI and the server come from the same tag. The two versions that match are
the pair we test.

The CLI's built-in default `base_url` is the hosted instance,
`https://managoat.com`, and not yours. Point it at your instance
before you export an API key. Otherwise the first command you run without a
config sends that key to the hosted domain.

```bash
FOUNTAIN_BASE_URL=https://your-fountain.example.com fountain auth login
```

`auth login` records the URL in the saved profile, so you do this one time.

## Watch a deploy land

```bash
kubectl rollout status deployment/fountain -n fountain   # k8s
docker compose logs -f app                               # compose
```

A rollout that never completes usually means the startup probe fails, and that
means migrations that cannot finish. The readiness probe can also fail,
against a database problem that is older than the deploy. Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).

## When an upgrade goes wrong

Here are the rules, best first.

1. **Roll forward.** Pin `vX.Y.Z` tags, read **Upgrade notes** before a minor
   bump, and fix forward when something breaks.
2. **Do not downgrade once a newer version's migrations have run.** We do not
   support it. The supported path back is to restore the pre-upgrade database
   backup and run the previous image. You then lose the writes since the
   backup. That is why a backup before each upgrade is cheap insurance.
3. `Fountain.Release.rollback/2` exists to reverse one migration that you
   understand. Do not attempt to reverse a whole release's migrations on
   production data.

If a restore crosses an upgrade boundary, run the image version that matches
the dump.

## Related

- [Back up and restore](back-up-and-restore.md).
- [Run a release task](run-a-release-task.md), for `rollback/2` and
  `migrate/0`.
- [Changelog](../../changelog.md).
