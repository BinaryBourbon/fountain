# Wire up observability

This guide shows you how to scrape metrics. It also shows you how to import
the dashboard and alerts that ship with the repo, and where to point your
health checks.

## Metrics

The app serves Prometheus metrics on port 9568. The compose file does not
publish that port. Map the port to scrape it, and keep it off the public
internet. The endpoint lists routes, request rates and database timings.

You do not have to start from an empty scrape. The repo ships an
observability pack, built from a real run of the hosted instance.

- **Alerts**, in `deploy/k8s/prometheusrule.yaml`. They cover error rate,
  unhandled exceptions, pool saturation, failures to provision, and staleness
  watches for the optional backup CronJob. Each one carries a comment that
  says what it means and what to do. It needs the PrometheusRule CRD, and it
  sits commented out of the kustomization until you turn it on.
- **A starter dashboard**, in `deploy/grafana/fountain-dashboard.json`. It is
  built from metrics the app truly exports, and from nothing else. Import it
  into Grafana, then choose your Prometheus datasource. On compose, point any
  Prometheus at the metrics port and import the same file.
- **Three team dashboards**, in `deploy/grafana/`, one each for ops, product
  and finance. They cover the same metrics in more depth, and the ops one adds
  trace panels. [Read the dashboards](dashboards.md) says what each number
  means, and which questions belong in PostHog instead.

One series gets a mention here, because it is the one that maps to money.
The gauge `fountain_sandboxes_by_provider_count` reports how many sandboxes
each provider holds right now, by status. See
[See what sandboxes cost](sandbox-spend.md) for the per-account view that goes
with it.

## Logs

Logs go to stdout.

```bash
docker compose logs -f app
```

## Errors

Fountain reports no error unless you opt in. Set `SENTRY_DSN`. Sentry then
receives each crash with a stack trace, groups them, and matches them to
releases. That includes the crashes that never touch a web request.

The endpoint can be sentry.io, or any service that speaks the Sentry API. Use
GlitchTip for a stack you host yourself. Leave the variable unset and nothing
ever leaves your instance.

The [Sentry integration guide](../../integrations/sentry.md) covers the setup,
and the Crons pattern that alerts you when the backup job stops.

## Health endpoints

There are two, because a restart of a container and a removal from a load
balancer are different decisions.

| | |
|---|---|
| `GET /health` | Always 200 while the app runs. It checks nothing. Point a **restart** check here. If it read the database, one Postgres blip would restart each container at once, and that does not fix Postgres. |
| `GET /health/ready` | 200 when this instance can serve, and 503 when it cannot reach its database. Point your **load balancer** and your deploy gates here. |

```bash
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

Both are public, and neither asks for authentication. Each reports `ok` or
`error` for each check, with no more detail. A check that fails does not
describe your database to whoever asked.

A healthy check takes about 2ms. A database it cannot reach takes a few
seconds to give up. Give the check a timeout above one second when your
platform defaults lower.

## Related

- [Sentry integration guide](../../integrations/sentry.md).
- [Pods restart or never go ready](../../troubleshooting/pods-restarting.md),
  which explains the probe layout as symptoms.
- [Architecture](../../architecture.md), for which component owns which
  symptom.
