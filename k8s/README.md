# `k8s/` — the manifest artifact

This directory is **not** a deployment you apply. It is the layer
`publish-manifests.yml` publishes to `ghcr.io/binarybourbon/fountain-manifests`
on every merge to `main`: the portable baseline in [`../deploy/k8s`](../deploy/k8s)
plus [`pin.yaml`](pin.yaml), which names the image built from this tree.

- **Self-hosting?** Use [`deploy/k8s/`](../deploy/k8s) directly. Its README is
  the guide, and [docs/guides/operate/kubernetes.md](../docs/guides/operate/kubernetes.md)
  says which manifests to apply.
- **The hosted instance** (`fountain.inevitable.fyi`) is this artifact plus a
  private overlay — CNPG, Infisical, Traefik, backups, alerts, hostnames —
  that lives in the maintainer's home-cloud repo and is applied by Flux. It
  used to live here; [decisions/0032](../decisions/0032-hosted-overlay-leaves-the-repo.md)
  records why it left.

Two rules keep the pairing honest:

1. `pin.yaml`'s image tag and `FOUNTAIN_BUILD_SHA` are placeholders in git.
   The workflow substitutes both and fails the publish if either does not
   land, so a stale tag can never ship silently.
2. Anything the artifact needs must be under `k8s/` or `deploy/` — the
   workflow stages exactly those two trees and builds the staged copy before
   pushing, so a reference outside them fails in CI rather than in Flux.
