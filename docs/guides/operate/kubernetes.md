# Deploy on Kubernetes

This guide shows you which manifests to apply, and which to read but not apply.

## Use `deploy/k8s/`

A portable baseline lives in
[`deploy/k8s/`](https://github.com/BinaryBourbon/fountain/tree/main/deploy/k8s).
Plain manifests applied with `kubectl apply -k`, with no operators or CRDs
assumed.

You bring a Postgres, an ingress controller, and the `fountain-secrets` Secret.
Its README walks through the rest, and the probe and scaling reasoning is
commented inline in the manifests.

## Do not apply `k8s/`

`k8s/` in this repository is a different thing. It is the maintainer's own
cluster, with CNPG, Traefik, cert-manager, Infisical, Flux, Longhorn and
personal hostnames.

It is worth reading, because it shows the full Erlang-clustering wiring for
running more than one replica. It is not worth applying.

## Two things to decide

**Migrations.** Boot migrations are safe with several replicas, serialized by a
Postgres advisory lock. If you would rather run them as an explicit Job, see
[Running migrations in a Job](database.md#running-migrations-in-a-job).

**Backups.** `deploy/k8s/backup-cronjob.yaml` is commented out of the
kustomization until you create its secret. See
[Back up and restore](back-up-and-restore.md).

## Verify it worked

```bash
kubectl rollout status deployment/fountain -n fountain
kubectl exec -n fountain deploy/fountain -- curl -sS localhost:4000/health/ready
```

## If it did not work

See [Pods restarting or not ready](../../troubleshooting/pods-restarting.md).
Most "kubernetes is broken" symptoms here are the probe layout working as
designed.

## Related

- [Wire up observability](observability.md), for the PrometheusRule.
- [Back up and restore](back-up-and-restore.md).
- [Architecture](../../architecture.md), for the clustering picture.
