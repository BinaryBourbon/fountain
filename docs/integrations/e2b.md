# E2B

[E2B](https://e2b.dev) is one of the three
[sandbox providers](sandbox-contract.md). Setting
`E2B_API_KEY` enables it; `SANDBOX_PROVIDER=e2b` makes it the default for
newly-created sandboxes, and an individual agent can pin it via
`sandbox_provider`. Existing sandboxes always stay on the provider they were
created on.

```bash
E2B_API_KEY=e2b_...          # enables the provider
E2B_TEMPLATE=fountain        # a template built from images/e2b/ (see below)
# E2B_BASE_URL=https://api.e2b.app
# SANDBOX_PROVIDER=e2b       # make it the instance default
```

## Template

The stock `base` template does not carry the agent CLIs. Build the reference
template once per account:

```bash
cd images/e2b
e2b template build --name fountain --dockerfile e2b.Dockerfile
```

It recreates the sandbox shape the provisioning pipeline assumes — a
`sprite` user with passwordless sudo, `/home/sprite`, node/npm/bun/git and
the four agent CLIs — so no per-provider provisioning code exists.

## How the contract maps

| Fountain operation | E2B mechanics |
|---|---|
| Name-keyed create/adopt | E2B assigns ids; the minted name rides in sandbox `metadata` and lookups filter on it server-side. A create race leaves a duplicate the reaper converges |
| Suspend / resume | Real calls: `pause` snapshots filesystem + memory (retained indefinitely, storage-only cost); `connect` restores. The idle bound genuinely parks |
| TTL | Every running E2B sandbox has one. Live commands heartbeat it, and sandboxes are created with `autoPause: true`, so a missed heartbeat pauses (state preserved) rather than kills. Operations that find the sandbox auto-paused resume it first |
| Exec / streaming | envd (the in-sandbox daemon) over Connect-RPC with the JSON codec — plain HTTPS, no gRPC |
| Reattach after a deploy | envd does not replay a reconnected process's output, so detachable commands run under a journaling shim (`tee` to `/tmp/fountain/<tag>.*`); reattach replays the journal from byte zero via a `tail` streamer and reads the real exit code from the shim's exit file |
| Network policy | Native default-deny: `denyOut 0.0.0.0/0` plus the allowlist, updatable on a running sandbox — the provision-open-then-lock flow works unchanged |
| Checkpoints | Not supported (`:checkpoint` is not advertised) |

## Operational notes

- **Plans**: agent turns can exceed one hour; E2B's Hobby tier caps
  continuous runtime at 1h, so Pro is effectively required.
- **Reaper**: reconciliation lists both `running` and `paused` sandboxes,
  filtered to `fountain`-stamped metadata; other sandboxes on the account
  are never touched.
- **Egress**: the callback host (`PUBLIC_URL`) must be reachable from
  inside; `limited` environments get it via the same allowlist mechanics as
  Sprites.
