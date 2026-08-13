# Operations

What to do when something is wrong with a running instance.
[Architecture](architecture.md) tells you which component owns a symptom;
this page is the action level — what to run, and what the output means.
Commands are shown for both deploy paths where they differ.

---

## Running a release task

Every operator action that touches data goes through one invocation pattern.
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

`eval` starts only the database connection, never the app — a task cannot
compete with the running server for ports, background jobs, or conversation
processes. `PHX_SERVER=false` makes that explicit in an environment where the
container sets it `true`; include it and the pattern is always safe to paste.

The tasks:

| Task | What it does |
|---|---|
| `Fountain.Release.verify_email("a@b.c")` | Mark an account's email verified without sending anything — the escape hatch for a broken mail provider (`EMAIL_DELIVERY=none` self-verifies at registration since ADR 0011) |
| `Fountain.Release.promote_admin("a@b.c")` | Grant the admin role, recorded in the admin audit trail with a system actor. The manual alternative to `FIRST_USER_ADMIN=true` (ADR 0011) |
| `Fountain.Release.expire_legacy_trials(dry_run: true)` | Report (then, without `dry_run`, backfill) trial end dates on legacy `trialing` accounts that have none |
| `Fountain.Release.migrate()` | Run pending migrations by hand — what `bin/migrate` runs. They already run at every boot unless `MIGRATE_ON_BOOT=false`, in which case this (in a Job, before the rollout) is how they run at all. Never skipped by that switch |
| `Fountain.Release.rollback(Fountain.Repo, version)` | Roll migrations back to a version. Last resort — see [Upgrade gone wrong](#upgrade-gone-wrong) before reaching for it |

---

## A conversation is stuck or failed

Open the conversation's log view. Provisioning progress is recorded as stage
events — `provision`, `checkpoint_restore`, `packages`, `network`, `clone`,
`setup`, `turn` — and the failing step names itself, with the exit code in
the event data.

- **`packages`, `clone` or `setup` failed** — almost always the environment's
  own configuration: a package that does not exist, a repository the token
  cannot reach, a setup script exiting non-zero. Fix the environment and
  prompt again.
- **`provision` failed outright** — the sprite could not be created: the
  Sprites platform is unhealthy, `SPRITES_TOKEN` is invalid, or the user is
  at their concurrent-sandbox quota. See [Sprites errors](#sprites-errors).
- **Stuck with no failure** — a conversation `running` with no events
  arriving usually means the sprite-side process died and the exit was
  missed. Interrupt it, or just send another prompt — waking reattaches to
  the existing sprite when it still exists:

    ```bash
    fountain conv show <conv-id>          # turn status, sandbox name
    fountain conv interrupt <conv-id>     # stop the in-flight turn, keep the sandbox
    fountain conv terminate <conv-id>     # destroy the sprite, end the conversation
    ```

What the statuses mean: `failed` and `terminated` are the two terminal
states — a further prompt is refused. `idle` with a *suspended* sandbox is
the normal resting state, not an error: the sprite is parked at sprites.dev,
scaled to zero, and the next prompt wakes it with the agent's memory intact.
`idle` with a *terminated* sandbox is what the max-lifetime ceiling (or an
explicit reap) leaves behind: the next prompt provisions fresh, the stored
transcript is unaffected, but the agent starts a fresh session — see the note
under [Primitives → Conversation](primitives.md).

**Quota knock-on:** a crash mid-provision leaves a `pending`/`starting`
sandbox row that counts against the user's quota (default 5 concurrent).
The reaper runs hourly at :07 and releases rows stuck longer than 60
minutes; an admin can raise a user's cap from `/admin` immediately. The
reaper logs one summary line per run:

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 destroyed=2 untracked=102 live=114
```

(`parked` is the reaper suspending idle server-less sandboxes — reversible
bookkeeping, not a teardown.)

---

## Pods restarting or not ready

The probe layout is deliberate, and most "kubernetes is broken" symptoms are
it working as designed:

- **Liveness checks nothing but the process.** A restart does not fix
  Postgres, so `/health` always answers 200 while the BEAM runs.
- **Readiness checks Postgres.** A pod that cannot reach its database
  answers 503 on `/health/ready`, is drained from the Service without being
  killed, and recovers on its own — **NotReady during a database blip with
  no restarts is the system behaving correctly.** Answering that 503 takes
  ~3 seconds, so give external checks a timeout above that.
- **The startup probe holds the others off for up to 150 seconds** because
  migrations run at boot, before the listener opens. A slow migration is not
  a dead pod.

Failure modes that are real:

- **Boot loop** — migrations cannot reach the database at all. The container
  fails before anything listens; check `DATABASE_URL` and the database
  itself.
- **A 301 where a probe expected 200** — on an `https://` instance every
  path redirects http to https *except* `/health` and `/health/ready`, which
  are exempt precisely because probes hit the pod over plain http. A check
  pointed at any other path scores the redirect as a failure. Point checks
  at the two health endpoints only.
- **Redirect loop in the browser** — the proxy in front is not setting
  `X-Forwarded-Proto`, so every request looks like http and gets redirected
  to itself. Fix the proxy header.

---

## Nobody can log in

Work down the chain:

1. **Did the verification email go anywhere?** Note the symptom: the password
   is accepted and the session is real, but it never leaves the "check your
   email" page, so this reads as a broken app rather than a refused login. An
   instance with `EMAIL_DELIVERY=none` sends nothing — that is the compose
   default. Verify by hand:

    ```bash
    docker compose exec app bin/fountain_server eval \
      'Fountain.Release.verify_email("them@example.com")'
    ```

2. **Mail configured but not arriving** — an unverified sending domain (SPF,
   DKIM, DMARC) is accepted by the provider and then rejected or spam-foldered
   downstream. See the [mail integration guide](integrations/mail.md).
3. **OAuth still works when mail does not.** GitHub sign-ins arrive already
   verified. Conversely, a GitHub outage breaks only the button — password
   auth is unaffected.
4. **Password reset needs working mail.** With `EMAIL_DELIVERY=none` a
   locked-out password account has no self-serve route back; that is the
   trade-off the mode's boot notice warns about.
5. **429 responses** — the API rate limit is 600 requests/minute per IP. If
   *everyone* is rate-limited at once behind a proxy, `TRUSTED_PROXIES` is
   unset and every client is sharing the proxy's bucket.

---

## Sprites errors

What the retries already cover: transient Sprites failures (5xx, 429,
timeouts) on the provisioning path are tried up to three times (two retries)
with exponential backoff, each call bounded by `SPRITES_TIMEOUT_MS` (default
30s). You only
see a failure after that has been exhausted.

What a 4xx means — these are deliberately **not** retried:

- **401/403** — `SPRITES_TOKEN` is invalid, revoked, or missing. Check this
  first; it fails every conversation while everything else looks healthy.
- **409 on create** — already handled: the existing sprite is adopted, not
  an error you will see.

During a Sprites outage: new conversations and wakes fail (a fresh provision
marks the conversation `failed`; a wake leaves it resumable for later),
while sign-in, dashboards, configuration and past logs keep serving. The
readiness probe deliberately excludes Sprites — a third party's uptime does
not belong on the serving path — so do not expect pods to go NotReady over
it. If you scrape metrics, provisioning failures show as
`fountain_stage_count{stage="provision", status="failed"}` (and completions
as `status="done"`).

---

## Backup and restore

A backup here is two things: a `pg_dump` of Postgres **and the
`MASTER_SECRETS_KEY` it was written under**. The key wraps every tenant's
encryption key; a dump restored without it has secrets that nothing will
ever decrypt. Store the key separately from the dumps, and treat "which key
was live when this was taken" as part of a backup's identity.

Taking them:

- **Compose** — the bundled service, opt-in:
  `docker compose --profile backup up -d`. Nightly `pg_dump` into the
  `backup_data` volume, pruned after 14 days
  ([details](self-hosting.md#backups)).
- **Kubernetes** — `deploy/k8s/backup-cronjob.yaml`, nightly to any
  S3-compatible bucket, commented out of the kustomization until you create
  its secret. Setup is at the top of the file.

### The restore drill

A backup nobody has restored is a hypothesis. Periodically — and always
before an upgrade — restore the newest dump into a scratch database and look
at it. Compose:

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

Kubernetes: fetch the dump from the bucket and do the same against a scratch
database on your Postgres:

```bash
aws s3 cp s3://<bucket>/pg_dump/fountain-<ts>.dump .
createdb -h <host> -U <user> fountain_drill
pg_restore --no-owner -h <host> -U <user> -d fountain_drill fountain-<ts>.dump
```

The drill passes when the counts look like production and the newest rows
are from the night of the dump — not when `pg_restore` merely exits zero.

### Restoring for real

Stop the app first so nothing writes mid-restore (`docker compose stop app`,
or scale the deployment to zero), then replace the live database and start
the app again:

```bash
pg_restore --clean --if-exists --no-owner -d "$DATABASE_URL" fountain-<ts>.dump
```

Two rules that decide whether this works:

- The restored data decrypts only under the `MASTER_SECRETS_KEY` that was
  live when the dump was taken. If you rotated the key since, you need the
  old one.
- If the restore crosses an upgrade boundary, run the image version that
  matches the dump — see [Upgrade gone wrong](#upgrade-gone-wrong).

### Knowing the job still runs

A backup job that quietly stops is the classic way backups rot. The
Kubernetes CronJob has the [Sentry Crons
check-in](integrations/sentry.md#crons-alerting-when-a-scheduled-job-stops-running)
built in — set `SENTRY_DSN` and arm the monitor's schedule. On compose,
check the service's log line dates:

```bash
docker compose --profile backup logs backup | tail -5
```

---

## Upgrade gone wrong

The rules, in order of preference:

1. **Roll forward.** Pin `vX.Y.Z` tags, read **Upgrade notes** in the
   [changelog](changelog.md) before a minor bump, and fix forward when
   something breaks.
2. **Downgrading is not supported once a newer version's migrations have
   run.** The supported path back is restoring the pre-upgrade database
   backup and running the previous image — accepting the loss of writes
   since the backup. This is why a backup taken before every upgrade is
   cheap insurance.
3. `Fountain.Release.rollback/2` exists for surgically reversing a migration
   you understand. Reversing an arbitrary release's migrations is not
   something to attempt on production data.

Watching a deploy land:

```bash
kubectl rollout status deployment/fountain -n fountain   # k8s
docker compose logs -f app                               # compose
```

A rollout that never completes is usually the startup probe failing —
migrations that cannot finish — or a readiness probe failing against a
database problem that predates the deploy.
