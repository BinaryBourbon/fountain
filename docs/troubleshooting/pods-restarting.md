# Pods restarting or not ready

This guide shows you how to tell the probe layout working as designed from a
real failure.

Most "kubernetes is broken" symptoms here are the first thing.

## What is working as designed

**Liveness checks nothing but the process.** A restart does not fix Postgres,
so `/health` always answers 200 while the BEAM runs.

**Readiness checks Postgres.** A pod that cannot reach its database answers 503
on `/health/ready`, is drained from the Service without being killed, and
recovers on its own. **NotReady during a database blip with no restarts is the
system behaving correctly.** Answering that 503 takes about 3 seconds, so give
external checks a timeout above that.

**The startup probe holds the others off for up to 150 seconds**, because
migrations run at boot, before the listener opens. A slow migration is not a
dead pod.

## Failure modes that are real

**Boot loop.** Migrations cannot reach the database at all. The container fails
before anything listens. Check `DATABASE_URL` and the database itself. See
[Connect a database](../guides/operate/database.md).

**A 301 where a probe expected 200.** On an `https://` instance every path
redirects http to https *except* `/health` and `/health/ready`, which are
exempt precisely because probes hit the pod over plain http. A check pointed at
any other path scores the redirect as a failure. Point checks at the two health
endpoints only.

**Redirect loop in the browser.** The proxy in front is not setting
`X-Forwarded-Proto`, so every request looks like http and gets redirected to
itself. Fix the proxy header. See
[Put it on the internet](../guides/operate/put-it-on-the-internet.md).

**A rollout that never completes.** Usually the startup probe failing, meaning
migrations that cannot finish, or a readiness probe failing against a database
problem that predates the deploy. See
[Upgrade an instance](../guides/operate/upgrade.md).

## Related

- [Wire up observability](../guides/operate/observability.md), for what each
  health endpoint is for.
- [Deploy on Kubernetes](../guides/operate/kubernetes.md).
- [Architecture](../architecture.md), for which component owns which symptom.
