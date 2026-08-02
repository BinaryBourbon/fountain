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
| `Fountain.Release.verify_email("a@b.c")` | Mark an account's email verified without sending anything — the escape hatch for `EMAIL_DELIVERY=none` or a broken mail provider |
| `Fountain.Release.promote_admin("a@b.c")` | Grant the admin role, recorded in the admin audit trail with a system actor |
| `Fountain.Release.expire_legacy_trials(dry_run: true)` | Report (then, without `dry_run`, backfill) trial end dates on legacy `trialing` accounts that have none |
| `Fountain.Release.migrate()` | Run pending migrations by hand. They already run at every boot; this exists for unusual situations |
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
  missed. Interrupt it, or just send another prompt — waking provisions a
  fresh sandbox and the runtime resumes the same session:

    ```bash
    fountain conv show <conv-id>          # turn status, sandbox name
    fountain conv interrupt <conv-id>     # stop the in-flight turn, keep the sandbox
    fountain conv terminate <conv-id>     # destroy the sprite, end the conversation
    ```

What the statuses mean: `failed` and `terminated` are the two terminal
states — a further prompt is refused. `idle` with a terminated *sandbox* is
the normal resting state, not an error: the next prompt re-provisions and
history is preserved.

**Quota knock-on:** a crash mid-provision leaves a `pending`/`starting`
sandbox row that counts against the user's quota (default 5 concurrent).
The reaper runs hourly at :07 and releases rows stuck longer than 60
minutes; an admin can raise a user's cap from `/admin` immediately. The
reaper logs one summary line per run:

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 destroyed=2 untracked=102 live=114
```

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

1. **Did the verification email go anywhere?** Login is refused until the
   email is verified, and an instance with `EMAIL_DELIVERY=none` sends
   nothing — that is the compose default. Verify by hand:

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
timeouts) on the provisioning path are retried three times with exponential
backoff, each call bounded by `SPRITES_TIMEOUT_MS` (default 30s). You only
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
`fountain_provision_exception_count`.

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
