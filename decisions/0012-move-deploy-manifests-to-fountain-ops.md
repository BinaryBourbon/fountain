# 0012 — Move deployment manifests out of this repo, to fountain-ops

**Status:** Proposed. Nothing this ADR describes is built: `k8s/`,
`deploy/`, and `publish-manifests.yml` are all still here and still what
production deploys from. Every mechanism below is future work, gated as
stated.

## Context

This repo carries two manifest trees with different audiences:

- **`deploy/k8s/`** — the portable self-hosting baseline: plain manifests,
  `kubectl apply -k`, no operators. It is the Kubernetes path in the public
  docs (`docs/self-hosting.md`, `docs/operations.md`), and `deploy/grafana/`
  carries the starter dashboard those docs point at.
- **`k8s/`** — the maintainer's production cluster, expressed as a kustomize
  overlay **based on `../deploy/k8s`** (#264): CNPG, Infisical, Traefik,
  Erlang clustering, hostnames, and the image pin. `publish-manifests.yml`
  publishes base + overlay + pin as one OCI artifact
  (`ghcr.io/binarybourbon/fountain-manifests`) that Flux reconciles — the
  atomicity that #231 bought and #304 moved off the `deploy` branch.

[fountain-ops](https://github.com/INTENTIUS/fountain-ops) now exists as a
standalone deployment product: it generates manifests from declared seams,
and its seam modes — `postgres=cnpg`, `secrets=infisical`,
`ingress=traefik`, `monitoring=prometheus-operator` — are exactly the
components the `k8s/` overlay is made of. Both trees here now have a
successor whose whole job is deploying Fountain, which raises the question
of why the application repo still carries per-cluster deployment detail.

The two trees are coupled: `k8s/` cannot outlive `deploy/k8s` without being
flattened, so they leave together or not at all.

## Decision

**Remove `k8s/` and `deploy/` from this repo; fountain-ops becomes the
source of both the self-hosting Kubernetes path and the production
manifests.** This repo keeps the application's deployable contract and
nothing cluster-shaped: the `Dockerfile`, image and release publishing,
`docker-compose.yml` (the quick-start front door), the `/health` endpoints,
and `.env.example`. How any particular cluster runs the image — the
maintainer's included — lives in fountain-ops.

Sequenced in three gates, in order:

1. **Verification gate.** fountain-ops `target=kubernetes` is today
   builds-only (fountain-ops#22: the Traefik/Infisical/prometheus-operator
   controllers are not installed in its harness), and turn completion still
   races (fountain-ops#67). Before anything is deleted here, a diff harness
   must show fountain-ops with a production parameter set emitting manifests
   semantically equivalent to `kustomize build k8s/`. That harness is both
   the #22 verification and this migration's safety net.
2. **Production cutover.** fountain-ops (or automation it owns) becomes the
   publisher of the OCI artifact Flux reconciles, replacing
   `publish-manifests.yml`. This is where the deploy-cadence decision is
   forced — see Consequences. The `fountain-artifact-receiver` webhook wiring
   in home-cloud changes to match.
3. **Removal.** The self-hosting docs cut over to fountain-ops, and
   `k8s/`, `deploy/`, and `publish-manifests.yml` are deleted in one PR.
   Path-gating in `build.yml` simplifies accordingly.

Where the production parameter set lives (fountain-ops has `secrets/` +
sops and can carry it; a small config in home-cloud invoking fountain-ops
is the alternative) is decided at gate 2, not here.

## Consequences

- **The #231/#304 atomicity must be re-earned, not assumed.** Today the
  manifests, the overlay, and the image pin live in one tree and ship as one
  artifact by construction; #241 is the incident that happens when they
  skew. Moving manifests out of this repo reconstructs the cross-repo skew
  problem unless the cutover design closes it — either production moves to
  release-cadence deploys (fountain-ops pins releases like `v0.4.1` today),
  or per-merge automation bumps the pin in fountain-ops and republishes.
  Today every merge to `main` reaches production in ~10 minutes as a
  `sha-…` tag; whether that property survives is the central open question
  of gate 2.
- **Self-hosters lose the plain-manifests path.** `deploy/k8s` is
  operator-free `kubectl apply -k`; fountain-ops brings a toolchain (node,
  chant, just). The docs cutover trades "copy these manifests" simplicity
  for a maintained, verified product — deliberate, but a real trade.
- **Manifest validation moves.** The kubeconform/promtool checks in
  `publish-manifests.yml` (#414: nothing deployed unvalidated) must have
  equivalents in fountain-ops CI before gate 2.
- **The grafana dashboard** (`deploy/grafana/fountain-dashboard.json`)
  becomes a monitoring-seam artifact in fountain-ops.
- Historical ADRs and docs reference `k8s/` and `deploy/` paths; per 0010's
  precedent they describe their time and are not rewritten. Live docs
  (`self-hosting.md`, `operations.md`, `architecture.md`, `README.md`) are
  updated at gate 3.
- Rollback semantics change: today it is
  `flux tag artifact … --tag latest` against this repo's artifacts; the
  equivalent must be documented in fountain-ops before cutover.

## Alternatives considered

- **Status quo — keep both trees here.** Two sources of truth for the same
  deployment as fountain-ops matures; every prod change made twice or the
  trees silently diverge.
- **Move `deploy/` only, keep `k8s/`.** Requires flattening the overlay
  (losing the #264 base/overlay separation) and leaves the app repo carrying
  the maintainer's cluster — the least defensible tree of the two.
- **Move `k8s/` to home-cloud instead of fountain-ops.** Keeps prod config
  private, but duplicates fountain-ops's manifest generation instead of
  exercising it; the maintainer's cluster stops being a consumer of the
  product, which is half the point of having one.
- **Do it now, without gate 1.** Deletes a working, documented path in
  favor of one whose Kubernetes target is unverified (fountain-ops#22).
