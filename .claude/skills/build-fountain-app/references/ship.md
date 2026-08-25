# Ship an app to home-cloud (`<name>.inevitable.fyi`)

The demo-suite shape: every app is its own repo under `jhgaylor/`, builds an
nginx (or Bun) image on GitHub Actions, pushes to GHCR, pins the sha into its
own `k8s/deployment.yaml`, and Flux in `jhgaylor/home-cloud` rolls it. Copy
the files from `~/dev/jhgaylor/fountain-demos` (pure static) or
`~/dev/BinaryBourbon/fountain-workbench` (static + Bun server + SQLite PVC).

## Files

| File | Notes |
|---|---|
| `Dockerfile` | `nginx:alpine` + `COPY dist/` (static) or `oven/bun:1-alpine` + `COPY server/ shared/ dist/`. **Build the SPA on the runner, not in the image** — the image stage is a plain copy, so multi-arch costs nothing and no QEMU bun. |
| `nginx.conf` | SPA fallback to `index.html`; `/assets/*` immutable 1y; everything else `no-cache`; `/healthz` 200. |
| `.dockerignore` | `node_modules`, `.git`, `src` (dist is what ships). |
| `.github/workflows/ci.yml` | on PR + main: `bun install --frozen-lockfile`, `typecheck`, `bun test`, `build`, upload `dist`. |
| `.github/workflows/build.yml` | on push to main (`paths-ignore: k8s/**, README.md`): buildx `linux/amd64,linux/arm64` (home-cloud's k3s nodes are arm64 Lima VMs) → `ghcr.io/jhgaylor/<name>:{latest,sha-<sha>}` → `sed` the sha into `k8s/deployment.yaml` → bot commit `deploy: pin image sha-…`. `concurrency: build-main`, `cancel-in-progress: false`. |
| `k8s/namespace.yaml`, `deployment.yaml`, `service.yaml`, `ingressroute.yaml` (websecure + web→https redirect, Traefik), `certificates.yaml` (`letsencrypt-production`), `kustomization.yaml` | Probes on `/healthz`. A server with SQLite: `replicas: 1`, `strategy: Recreate`, 1Gi Longhorn RWO PVC, `envFrom` secretRef `optional: true`. |

Wildcard DNS `*.inevitable.fyi` already resolves. GHCR packages under
`jhgaylor` are born public. Static-only apps can alternatively stay on GitHub
Pages at `jakegaylor.com/<repo>/` (fountain-team does; `VITE_BASE=/<repo>/`,
`pages.yml`) — the redirect URI then has that path.

## Onboarding to home-cloud (a home-cloud PR)

`chant/src/apps.ts` + `names.ts` → `npm run build` in `chant/` regenerates
`clusters/home/control-plane/manifests.yaml` (a `GitRepository` + a
`Kustomization` per app). After merge, a new Kustomization can sit on
`dependency cert-manager is not ready` with stale status until
`flux reconcile kustomization flux-system` cascades; the pods are usually fine.

## Registering with Fountain (a fountain PR)

`~/dev/jhgaylor/home-cloud/platform/fountain-site/patches/deployment.yaml`:

- append `https://<name>.inevitable.fyi` to `API_CORS_ORIGINS` (exact origin, comma-separated, no path);
- append `{"id":"<name>","name":"<Title>","redirect_uris":["https://<name>.inevitable.fyi/"]}` to the `OAUTH_CLIENTS` JSON.

And in this repo, `config/dev.exs` `:oauth_clients` gets the same id with
`http://localhost:5173/` and `http://localhost:5174/`.

Deploy is a Flux reconcile of `fountain-site`; confirm the pod env before
testing sign-in (`kubectl -n fountain exec deploy/fountain -- env | grep OAUTH`).
A deploy rolls the pods, which kills any provision in flight — check for
`starting` sandboxes first.

## Verify

1. `curl -sI -H 'Origin: https://<name>.inevitable.fyi' -H 'Access-Control-Request-Method: GET' -X OPTIONS https://fountain.inevitable.fyi/api/auth/me` → `access-control-allow-origin` present.
2. Sign in from the hosted build in **Firefox** and Chrome; a stray `oauth:<name>` key per failed attempt under Account → API keys means the callback threw after the exchange.
3. Hire a teammate, send one message, watch `turn/done` arrive on the stream.
4. Traps from previous rollouts: `build.yml` sometimes doesn't fire on the repo-creation push (`gh workflow run build`); `ImagePullBackOff` on the `sha-000…` placeholder means Flux hasn't fetched the pin commit (`flux reconcile source git <name>`).
