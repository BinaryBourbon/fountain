# 0018 — Pluggable sandbox backends: the `Fountain.Sandbox` abstraction

**Status:** Accepted (2026-08-14). Everything described here is built and
merged (#676–#686); the one exception is called out explicitly in
[Verification status](#verification-status).

Amends [0005](0005-platform-shared-sprites-token.md) (one platform
credential *per provider*), reaffirms
[0017](0017-suspend-idle-sandboxes.md) with a capability-degradation rule,
and supersedes the two-implementation cap in
[0016 §5](0016-governance-as-an-acp-proxy.md).

## Context

Every conversation runs inside a sandbox, and until this campaign the
`sprites-ex` SDK was called directly from ~15 modules — the test helper
even documented the choice ("without requiring us to wrap sprites-ex in an
adapter behaviour"). 0016 §5 sketched the intended seam — one
`Fountain.Sandbox` behaviour with a conformance suite — but capped it at
two implementations and gated the second on a named customer. The decision
here is to build the seam now and prove it with **two additional hosted
providers (E2B and Daytona)**, chosen over Modal (gRPC-only control plane —
no clean path from Elixir) and raw Firecracker microVMs (a platform build,
not an integration).

## Decision

### One behaviour, one facade, one error taxonomy

`Fountain.Sandbox` is both the `@behaviour` adapters implement and the
facade call sites use; nothing outside `lib/fountain/sandbox/` names a
provider SDK or its error shapes. Handles and commands are provider-tagged
structs whose `private` field is adapter-opaque (and excluded from
`inspect` — the Sprites handle embeds the platform bearer token). Errors
normalize into a closed taxonomy (`:not_found`, `{:rate_limited, _}`,
`{:unavailable, _}`, `{:denied, _}`, `{:invalid, _}`, `{:provider, _, _}`)
that `Fountain.Retry` classifies directly; the not-found/transient
distinction is load-bearing on the wake path, where only a definitive
not-found may give up a parked disk.

The owner-message contract for streaming commands is normative:
`{:stdout | :stderr, %{ref: ref}, bin}`, exactly one terminal frame
(`{:exit, %{ref: ref}, code}` or `{:error, %{ref: ref}, reason}`), a
deliberate close without an exit frame reads as exit 0, and **attach
replays buffered output from byte zero** — the byte-skip arithmetic in
reattach depends on it. `Fountain.SandboxConformanceCase` is the executable
form of all of this; `Fountain.Sandbox.Fake` (a real in-memory adapter
whose commands are actual processes) passes it in full and is the reference
implementation for adapter authors.

### Selection: instance default, per-agent override, sticky rows

`SANDBOX_PROVIDER` picks the default for newly-created sandboxes; a
provider is *enabled* by the presence of its credential plus a registered
adapter, and an explicitly-chosen default without credentials refuses to
boot. `agents.sandbox_provider` (nullable) overrides per agent, validated
against enabled providers at save time and re-checked at conversation
start. The resolved provider is stamped into `sandboxes.provider` at the
two mint sites and **never re-resolved**: a parked sandbox wakes on the
backend that holds its disk regardless of the instance default, and a row
whose (non-default) provider lost its credentials refuses to wake
retryably rather than being retired — retiring it would destroy the
agent's memory.

`sprite_name` keeps its name deliberately: it is the provider-scoped
identity Fountain mints, it is public API surface, and historical
audit/usage metadata keyed `"sprite_name"` is immutable.

### Capability flags and the lifecycle degradation rule

`capabilities/0` answers operational questions, most importantly
`:suspend`: *can an idle sandbox park with its disk preserved at
negligible cost?* Sprites advertises it implicitly (scale-to-zero; its
`suspend/1` is a no-op), E2B (pause) and Daytona (stop) with real calls. A
provider without it gets destroy-on-idle, priced exactly like the
max-lifetime ceiling. `Lifecycle.idle_action/1` is the single place this
decision lives, used by both the ConversationServer and the reaper.

Two failure policies, deliberately asymmetric:

- **suspend before the row flips; a failed suspend degrades to destroy** —
  an unparked sandbox keeps billing, so cost control wins;
- **resume before the row flips; a failed resume leaves the row
  suspended**, failing retryably — the parked disk is the agent's memory,
  so data protection wins.

0017's "suspended rows are never aged out" stands on every provider: E2B
retains paused snapshots indefinitely at storage-only cost, and Daytona
auto-archives long-parked filesystems to object storage (still startable,
slower) rather than expiring them.

### Per-provider reaping

The reaper's destroy/reconcile passes run per enabled provider with error
isolation: one backend's listing failure does not stop another's destroys,
rows on a provider whose listing failed (or whose credentials were pulled)
are skipped and logged rather than destroyed, and untracked counts carry a
provider tag. Usage-event metadata gains a `provider` key (the ee event
vocabulary itself stays closed).

### The two new adapters

**E2B** — ids are server-assigned, so the minted name rides in sandbox
metadata (create adopts an existing name; the reaper converges race
duplicates). Every running sandbox has a TTL, so live commands heartbeat it
and `autoPause: true` turns a missed heartbeat into a pause rather than a
kill; operations that find the sandbox auto-paused resume it first. envd
does not replay a reconnected process's output, so detachable spawns run
under a journaling shim (`tee` to `/tmp/fountain/<tag>.*`) and attach
replays via a `tail -c +1 -f` streamer with the real exit code read from a
sentinel file.

**Daytona** — the closest native match: name-addressed sandboxes, no TTL,
`stop`/`start` preserving the disk, and a server-side journal whose log
stream replays from byte zero natively. Stdin is a line-oriented FIFO with
no EOF operation (`close_stdin` is a documented no-op — the ACP path never
needs a mid-turn EOF).

Both providers' egress control is genuinely default-deny (E2B
`denyOut 0.0.0.0/0` + allowlist; Daytona `networkBlockAll` +
`domainAllowList`), so the intent-level `NetworkPolicy{allow: [...]}` needs
a fail-open translation only on Sprites, where it lives inside that
adapter. Both get reference images (`images/e2b/`, `images/daytona/`)
recreating the `sprite`-user layout the provisioning pipeline assumes, so
no per-provider provisioning code exists.

## Deviations from 0016 §5

0016 capped the abstraction at two implementations (Sprites + a
BYO-Kubernetes runner) and gated the second on a named customer. This ADR
supersedes that cap: the second and third implementations are hosted
providers, built now, because proving the seam against two differently-
shaped backends is what keeps it honest — E2B exercises the no-native-name
and TTL-treadmill paths, Daytona the native-replay path. The governance
bar 0016 set (egress policy, no-long-lived-credential provisioning,
exec + attach, reaper-drivable destruction) is exactly what the
conformance suite pins.

## Verification status

Adapter logic is tested full-stack against stubbed HTTP (including E2B's
Connect streaming end to end) and the conformance suite runs against the
Fake and Sprites adapters. **Live smoke tests against real E2B and Daytona
accounts have not run yet** — they need credentials, and E2B's Hobby tier
caps continuous runtime below a long agent turn (Pro is effectively
required). Until a live provision → turn → park → wake → terminate cycle
has passed on each provider, treat the adapters as integration-complete
but not production-proven.
