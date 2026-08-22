# Deploy on Kubernetes

This guide shows you which manifests to apply, and which to read and not
apply.

## Use `deploy/k8s/`

A portable baseline lives in
[`deploy/k8s/`](https://github.com/BinaryBourbon/fountain/tree/main/deploy/k8s).
They are plain manifests that you apply with `kubectl apply -k`. They assume
no operators and no CRDs.

You bring a Postgres, an ingress controller, and the `fountain-secrets`
Secret. Its README walks you through the rest. The manifests explain the
choices about probes and scale in inline comments.

## Do not apply `k8s/`

`k8s/` in this repository is a different thing. It is the maintainer's own
cluster, with CNPG, Traefik, cert-manager, Infisical, Flux, Longhorn and
personal hostnames.

Read it, because it shows the full Erlang cluster wiring for more than one
replica. Do not apply it.

## Two things to decide

**Migrations.** Boot migrations are safe with several replicas. A Postgres
advisory lock serializes them. To run them as a Job of their own instead, read
[Run migrations in a Job](database.md#run-migrations-in-a-job).

**Backups.** `deploy/k8s/backup-cronjob.yaml` sits commented out of the
kustomization until you create its secret. Read
[Back up and restore](back-up-and-restore.md).

## Verify it worked

```bash
kubectl rollout status deployment/fountain -n fountain
kubectl exec -n fountain deploy/fountain -- curl -sS localhost:4000/health/ready
```

## If it did not work

Read
[Pods restart or never go ready](../../troubleshooting/pods-restarting.md).
Most symptoms here that look like a Kubernetes fault are the probe layout at
work.

## Related

- [Wire up observability](observability.md), for the PrometheusRule.
- [Back up and restore](back-up-and-restore.md).
- [Architecture](../../architecture.md), for the cluster picture.
