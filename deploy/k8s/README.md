# Fountain on Kubernetes — portable baseline

Plain manifests, applied with `kubectl apply -k`. No operators, no CRDs, no
assumptions beyond a cluster and an ingress controller. This is the generic
counterpart to `k8s/` in the repo root, which is the maintainer's own cluster
(CNPG, Traefik, Infisical, Flux) and is worth reading but not worth applying.

The [compose path](https://binarybourbon.github.io/fountain/self-hosting/) is
simpler if you don't already live on Kubernetes — start there.

## What this does not include

- **A database.** Bring a Postgres 16+ and hand its URL to the app. If it
  doesn't serve TLS, set `DATABASE_SSL: "false"` in the ConfigMap.
- **TLS / ingress specifics.** `ingress.yaml` is a standard Ingress with the
  contract documented inline; wire it to your controller and certificates.
- **Secret management.** The manifests reference a `fountain-secrets` Secret;
  creating it is on you (plain Secret below, or your ESO/Vault/sealed-secrets
  machinery pointed at the same name).

## Quick start

```bash
# 1. The secrets. MASTER_SECRETS_KEY encrypts every stored secret — lose it
#    and they are unrecoverable, so back it up somewhere that is not the
#    cluster. See "Back up MASTER_SECRETS_KEY" in the self-hosting guide.
kubectl create namespace fountain
kubectl create secret generic fountain-secrets -n fountain \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')" \
  --from-literal=MASTER_SECRETS_KEY="$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" \
  --from-literal=DATABASE_URL="postgres://user:pass@your-postgres:5432/fountain" \
  --from-literal=SPRITES_TOKEN="your-sprites-token"

# 2. Edit configmap.yaml (PUBLIC_URL at minimum) and the image pin in
#    kustomization.yaml, then:
kubectl apply -k deploy/k8s

# 3. Watch it come up. Migrations run at boot under an advisory lock.
kubectl rollout status deployment/fountain -n fountain

# 4. Register, then verify your account (EMAIL_DELIVERY defaults to none):
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.verify_email(\"you@example.com\")'"
```

Then close registration (`REGISTRATION_ENABLED: "false"` + re-apply) and make
yourself admin — audit-recorded like any other role grant:

```bash
kubectl exec -n fountain deploy/fountain -- \
  sh -c "PHX_SERVER=false bin/fountain_server eval 'Fountain.Release.promote_admin(\"you@example.com\")'"
```

## Upgrades

Edit the tag in `kustomization.yaml`'s `images:` block and re-apply. `vX.Y.Z`
tags are immutable; `vX.Y` follows patches. Patch releases are always safe;
pre-1.0 minor bumps may carry **Upgrade notes** in the
[changelog](https://binarybourbon.github.io/fountain/changelog/). Migrations
run at boot, idempotently, under an advisory lock. Downgrades are not
supported once a newer version's migrations have run — restore from a backup.

## Operational notes

- **Probes**: liveness checks only the process (a Postgres blip must not
  restart the app tier); readiness checks the database and gates traffic; the
  startup probe allows 150s for boot-time migrations. Reasons are inline in
  `deployment.yaml`.
- **Metrics**: Prometheus format on port 9568 (`metrics`). Scrape in-cluster;
  never expose it.
- **Scaling**: one replica by default, and going higher is not just a number —
  see the comment atop `deployment.yaml`.
- **Backups**: nothing here backs up your database, and `MASTER_SECRETS_KEY`
  must be backed up separately from it — a database backup alone cannot
  decrypt itself.
