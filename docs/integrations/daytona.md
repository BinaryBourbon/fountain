# Daytona

[Daytona](https://daytona.io) is one of the three
[sandbox providers](sandbox-contract.md), and the closest semantic match
to the contract of any of them.
Setting `DAYTONA_API_KEY` enables it; `SANDBOX_PROVIDER=daytona` makes it
the default for newly-created sandboxes, and an individual agent can pin it
via `sandbox_provider`. Existing sandboxes always stay on the provider they
were created on.

```bash
DAYTONA_API_KEY=dtn_...            # enables the provider
DAYTONA_SNAPSHOT=fountain          # a snapshot built from images/daytona/ (unset = org default image)
# DAYTONA_API_URL=https://app.daytona.io/api   # self-hosted Daytona
# SANDBOX_PROVIDER=daytona
```

## Snapshot

The stock image does not carry the agent CLIs. Build the reference snapshot
once per organization:

```bash
cd images/daytona
daytona snapshot create fountain --dockerfile Dockerfile
```

## How the contract maps

| Fountain operation | Daytona mechanics |
|---|---|
| Name-keyed create/adopt | Native. Sandboxes are name-addressable in API paths, and a conflicting create adopts when a follow-up get succeeds |
| Suspend / resume | `stop` preserves the whole disk; `start` resumes it. Long-parked sandboxes auto-archive to object storage (still startable, slower) so they stop consuming disk quota |
| TTL | None. Sandboxes are created with `ttlMinutes: 0` and `autoStopInterval: 0`, and Fountain's own lifecycle owns suspension. No heartbeat needed |
| Exec | One-shot toolbox `process/execute` with cwd/env/timeout |
| Streaming / reattach | Daemon-side sessions journal output server-side, and the log websocket **replays from byte zero before following**, so reattach is the same stream opened again. The daemon publishes no exit code and its follow stream is unreliable at both ends, so the adapter's shim writes an exit sentinel and the stream reconnects with a byte-exact skip |
| Stdin | The daemon FIFO EOFs after every write, so stdin-consuming commands read from a `tail -f`-fed file; writes append via one-shot execs, and `close_stdin` kills the tail for a real EOF |
| Network policy | `networkBlockAll` + `domainAllowList` per sandbox, updatable on a running sandbox. Genuinely default-deny, so `allow: []` needs no translation |
| Checkpoints | Not supported (`:checkpoint` is not advertised) |

## Operational notes

- **Domain allowlist size**: Daytona caps `domainAllowList` around 20
  entries; a `limited` environment with a longer allowlist will be rejected
  by the API.
- **Org tiers**: lower tiers restrict egress by default and may not honor
  overrides, so check the organization's network settings if `limited`
  environments behave unexpectedly.
- **Reaper**: reconciliation lists `fountain`-labeled sandboxes only; other
  sandboxes in the organization are never touched.
