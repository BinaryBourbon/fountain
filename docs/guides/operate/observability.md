# Wire up observability

This guide shows you how to scrape metrics, import the shipped dashboard and
alerts, and point health checks at the right endpoints.

## Metrics

The app serves Prometheus metrics on port 9568, which the compose file does not
publish. Add a port mapping if you are scraping it, and keep it off the public
internet. It enumerates routes, request rates and database timings.

You do not have to start from a blank scrape. The repo ships an observability
pack built from running the hosted instance.

- **Alerts**, `deploy/k8s/prometheusrule.yaml`. Error rate, unhandled
  exceptions, pool saturation, provisioning failures, and staleness watches for
  the optional backup CronJob, each commented with what it means and what to
  do. Needs the PrometheusRule CRD, and is commented out of the kustomization
  until you enable it.
- **A starter dashboard**, `deploy/grafana/fountain-dashboard.json`, built only
  from metrics the app actually exports. Import it into Grafana and pick your
  Prometheus datasource. On compose, point any Prometheus at the metrics port
  and import the same file.

## Logs

Logs go to stdout.

```bash
docker compose logs -f app
```

## Error tracking

Error tracking is off unless you opt in. Set `SENTRY_DSN` and crashes are
reported with stack traces, grouped, and correlated with releases, including
the ones that never touch a web request.

The endpoint can be sentry.io or anything Sentry-API-compatible, such as
GlitchTip for a fully self-hosted stack. Unset, nothing ever leaves your
instance.

Setup and the Crons pattern for backup-job alerting are in the
[Sentry integration guide](../../integrations/sentry.md).

## Health endpoints

Two, because restarting a container and taking it out of a load balancer are
different decisions.

| | |
|---|---|
| `GET /health` | Always 200 while the app is running. Checks nothing. Point a **restart** check here. If it consulted the database, a Postgres blip would restart every container at once, which does not fix Postgres |
| `GET /health/ready` | 200 when this instance can serve, 503 when it cannot reach its database. Point **load balancer** and deploy gates here |

```bash
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

Both are public and unauthenticated, and report `ok` or `error` per check with
no further detail. A failing check does not describe your database to whoever
asked.

A healthy check takes about 2ms. An unreachable database takes a few seconds to
give up, so give the check a timeout above one second if your platform defaults
lower.

## Related

- [Sentry integration guide](../../integrations/sentry.md).
- [Pods restarting or not ready](../../troubleshooting/pods-restarting.md),
  where the probe layout is explained as symptoms.
- [Architecture](../../architecture.md), for which component owns which
  symptom.
