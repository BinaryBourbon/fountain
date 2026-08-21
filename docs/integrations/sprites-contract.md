# The Sprites transport reference

This page documents the **Sprites adapter's** transport contract, meaning every
endpoint `Fountain.Sandbox.Sprites` calls, the semantics it relies on, and
the operational assumptions baked in. The provider-neutral contract every
backend must meet is [the sandbox contract](sandbox-contract.md), which is the
`Fountain.Sandbox` behaviour and its conformance suite
(`Fountain.SandboxConformanceCase`), which the [E2B](e2b.md) and
[Daytona](daytona.md) adapters also satisfy. Evaluating a new backend
starts there; this page is the reference for what the original backend
actually provides.

Setup and cost model are in the [Sprites integration guide](sprites.md).
Transport summary: REST over HTTPS with `Authorization: Bearer <token>`, one
WebSocket transport for command execution, and an NDJSON-streaming endpoint
for checkpoints.

---

## The surface consumed

| Operation | Endpoint | What depends on it |
|---|---|---|
| Create sprite | `POST /v1/sprites`, JSON `{"name": …}`, allowed 120s | Every conversation start |
| Get sprite | `GET /v1/sprites/{name}`, where 404 → not-found | Waking a conversation, sandbox reuse |
| Destroy sprite | `DELETE /v1/sprites/{name}`, where **404 counts as success** | Terminate, the max-lifetime ceiling, the reaper, account deletion (idle suspension deliberately calls nothing, since the sprite scales to zero on its own) |
| List sprites | `GET /v1/sprites`, paginated, see below | The reaper's hourly reconciliation |
| Write file | `PUT /v1/sprites/{name}/fs/write?path=…&workingDir=…&mode=…&mkdirParents=…`, raw body | The env file, inline skills, runtime config files |
| Execute (blocking) | WebSocket `/v1/sprites/{name}/exec`, run to exit, collect output | Package installs, git clones, setup scripts, runtime preparation |
| Execute (streaming) | Same WebSocket, `detachable=true` | The agent turn itself |
| List sessions | `GET /v1/sprites/{name}/exec` → `{"sessions": […]}` | Reattaching after a deploy or crash |
| Attach session | WebSocket `/v1/sprites/{name}/exec/{session_id}` | Resuming a running turn |
| Checkpoint create | `POST /v1/sprites/{name}/checkpoint`, NDJSON response | Warm starts |
| Checkpoint restore | `POST /v1/sprites/{name}/checkpoints/{id}/restore`, NDJSON response | Warm starts |
| Network policy | `POST /v1/sprites/{name}/policy/network`, where success is **exactly 204** | Environments with `networking_type: limited` |

Pagination on `GET /v1/sprites` works as follows. The server pages (at 50, its choice, and the
client sends no page-size parameter) and the response carries `sprites`,
`has_more`, and `next_continuation_token`; the client passes
`continuation_token` back until `has_more` is false. Fountain refuses to act
on a partial listing, because a reconciler that saw half the account would draw
exactly the wrong conclusions.

---

## The exec transport

Command execution is a WebSocket upgrade of `/v1/sprites/{name}/exec`
(bearer token re-sent on the upgrade; ten seconds to complete it). The
command travels in the query string: `path` plus one repeated `cmd` per argv
entry, repeated `env=KEY=VALUE` pairs, `stdin=true|false`, optional `dir`,
optional `tty` with `rows`/`cols`, optional `detachable=true`.

Frames are binary with a one-byte stream id prefix:

| First byte | Meaning |
|---|---|
| `0` | stdin (client → server) |
| `1` | stdout |
| `2` | stderr |
| `3` | exit, followed by a 4-byte big-endian exit code |
| `4` | stdin EOF (client → server) |

In TTY mode the prefix disappears, so binary frames are raw terminal bytes and
JSON text frames carry control messages (`exit`, `resize`, `port`).

Two subtleties Fountain relies on.

- **A close without an exit frame is treated as exit 0.** A replacement that
  drops connections without sending frame `3` will make failed commands look
  successful.
- Per-command timeouts are enforced client-side; the turn itself runs
  unbounded and is ended by the [sandbox lifecycle](../architecture.md), not
  by the transport.

---

## Sessions

`detachable=true` on the spawn is the contract that makes deploys survivable:
the sprite-side process keeps running when the WebSocket drops, appears in
`GET /v1/sprites/{name}/exec` (with `id`, `command`, `created`,
`last_activity`, `is_active`, `tty`), and can be re-joined at
`/v1/sprites/{name}/exec/{session_id}`.

- A detached session reports `is_active: false` while nobody is connected,
  Fountain deliberately does not filter on it.
- **Attach replays the session's buffered output from the beginning, then
  tails.** There is no offset parameter. Fountain de-duplicates by counting
  the bytes it already persisted per stream and dropping that many from the
  replayed head, so a replacement must replay-from-start for that arithmetic to
  hold.

---

## Checkpoints

Create (`…/checkpoint`, singular) and restore
(`…/checkpoints/{id}/restore`, plural) both answer with NDJSON, one JSON
object per line as `{"type": "info"|"stdout"|"stderr"|"error", …}`, and the
create stream surfaces the new checkpoint's id, which Fountain stores on the
environment. The promise relied on: restoring a checkpoint reproduces the
filesystem state at create time, so the cold pipeline (packages, clone,
setup) can be skipped entirely. A failed restore is non-fatal, and Fountain
clears the stored checkpoint id and falls back to the cold path.

---

## Network policy

`{"rules": [{"domain": …, "action": "allow"|"deny", "include": …}]}`, and
the one semantic that matters most: **an empty rules list means no
enforcement, meaning allow-all rather than deny-all.** For a `limited` environment with an
empty allowlist, Fountain sends an explicit `{"domain": "*", "action":
"deny"}` (deliberately without `include: "defaults"`, which would re-add the
platform's own allowances). A replacement that treats `rules: []` as
deny-all is safer than Sprites here; one that ignores deny rules fails the
whole `limited` feature open.

---

## Operational assumptions

- **Timeouts.** Every REST call is bounded by `SPRITES_TIMEOUT_MS` (default
  30s); create alone is allowed 120s. Exec commands carry their own bounds:
  5s for a chmod, 30 to 120s for runtime probes and the setup script, 300s for a
  package install, 600s for a clone,
  unbounded for the turn.
- **Retries.** Transient failures, meaning 5xx, 429, timeouts and transport errors,
  are tried up to three times (two retries) with exponential backoff and
  jitter, on the provisioning path only. Other 4xx fail fast: a 401/403 is a token problem,
  not weather.
- **Idempotency is Fountain's job, not the API's.** Sprite names are unique
  per token (`fountain-<tenant-prefix>-<8 hex>`); a 409 on create means the
  sprite already exists and Fountain adopts it rather than erroring. Destroy
  tolerates 404. The hourly reaper converges anything the happy path leaked.
  A replacement only needs stable name-keyed create/destroy semantics.
- **Errors.** Any non-2xx surfaces as status + decoded body. Rate-limit
  responses carry structured bodies (`sprite_creation_rate_limited`,
  `concurrent_sprite_limit_exceeded`, `retry_after_seconds`), currently
  handled generically as 429s.
- **Billing.** One platform token pays for every sandbox (ADR 0005), which
  is why per-tenant concurrency quotas count from the moment provisioning
  begins, and why the reaper exists at all.

---

## The failure model

| When Sprites is… | What happens |
|---|---|
| Down at provision time | Bounded retries, then the conversation is marked `failed`. The stage events name the step |
| Down at wake time | The sandbox is marked `failed`; the conversation stays resumable and re-provisions on the next prompt |
| Dropped mid-turn | The detachable session keeps running sprite-side; reattach picks it up, replay-from-start plus byte-skip restores the stream |
| Slow | `SPRITES_TIMEOUT_MS` bounds each call; a timeout is retried like any transient failure |
| Down entirely | Everything that is not a sandbox keeps working, including sign-in, configuration and past logs. Readiness deliberately excludes Sprites, so pods do not go NotReady over a third party |

---

## What a replacement must provide

The checklist version: the twelve operations above, bearer auth, name-keyed
idempotent create/destroy (409 on duplicate, 404-tolerant delete), the
stream-id frame protocol with a real exit frame, detachable sessions with
replay-from-start, NDJSON checkpoints that actually restore filesystem
state, deny-capable network policy, and `has_more`/`next_continuation_token`
pagination. Get those semantics right, including the four subtle ones called
out above, and `SPRITES_BASE_URL` is the only thing that changes.
