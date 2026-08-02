# Sprites

**Required.** [sprites.dev](https://sprites.dev) is the sandbox platform every
conversation runs in. It is a hosted service and currently the only backend —
a Fountain instance is not fully self-contained without it.

The exact API surface Fountain consumes — and what a compatible replacement
behind `SPRITES_BASE_URL` would have to provide — is written down in
[the Sprites contract](sprites-contract.md).

## Provider side

Create a sprites.dev account and issue an API token. That token is the whole
provider-side setup.

## Env vars

| Variable | Default | Effect |
|---|---|---|
| `SPRITES_TOKEN` | — | The platform token. Not checked at boot: the app starts without it, and the first conversation fails at provision time instead |
| `SPRITES_BASE_URL` | `https://api.sprites.dev` | Repoints the sandbox API. Anything else must implement the same contract; there is no bundled alternative |
| `SPRITES_TIMEOUT_MS` | `30000` | Bounds every HTTP call to the Sprites API. Long-running commands (package installs, clones) set their own per-call timeouts. Boot refuses a non-positive value |

## The cost model

**One platform token pays for every sandbox.** Fountain provisions all
tenants' sandboxes with `SPRITES_TOKEN` and the bill lands on that token's
account — on the hosted instance, subscription pricing recovers it; on yours,
you are the one paying. Two consequences:

- Every signup that can start a conversation can spend your money. Close
  registration, or restrict it, before putting an instance on the internet.
- Per-user concurrency is capped (`max_concurrent_sandboxes`, default 5,
  adjustable per user from the admin panel). Sandboxes count from the moment
  provisioning begins, because that is when they start being paid for.

The token is never surfaced to tenants, the admin UI, or the sandboxes
themselves — a sprite receives only a scoped, expiring token whose sole
audience is your Fountain instance's own API.

## Verify

Start a conversation. Provisioning progress streams as stage events; a bad or
missing token surfaces as the `provision` stage failing, visible in the
conversation's log view. A Sprites outage does not affect anything else —
sign-in, dashboards and configuration keep working, and the health endpoints
deliberately do not consult Sprites.
