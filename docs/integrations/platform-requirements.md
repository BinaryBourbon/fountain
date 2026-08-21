# What Fountain needs from a sandbox platform

This page is written for **sandbox platform teams**. It is the list of things
Fountain had to build itself because no platform promised them, ordered by
what each one costs us, with an acceptance test for each so agreement can be
checked rather than assumed.

The two neighbouring pages have different audiences: [the sandbox
contract](sandbox-contract.md) is what the abstraction guarantees a Fountain
operator, and [adding a provider](adding-a-sandbox-provider.md) is the
checklist for writing an adapter. This one is what we would ask for if we
could ask.

Everything here is measurable against a real account, and every claim is
backed by an adapter in this repository. If one is wrong for your platform,
correcting it is cheaper for us than working around it.

## Why an agent turn is not a CI job

An agent turn runs for minutes or hours. It streams output a human is
watching in real time, it takes input mid-flight, and the filesystem it
leaves behind **is the agent's memory**, because the next turn resumes on that disk.
Our control plane redeploys underneath running turns and has to rejoin them,
and our reaper destroys sandboxes based on what a provider's API says exists.

Every platform we have integrated was designed for a shorter, more disposable
unit of work, and each is excellent at that. The gaps below cluster in one
place: the seam between a command and the process watching it. Three of the
four backends we ship can report that a command *ended* but not reliably
whether it *worked*, and none can tell us where in a stream we left off.

So we wrote the contract down as a behaviour, an error taxonomy and an
executable conformance suite, and made three hosted platforms pass it by
building the missing pieces inside their sandboxes with shell shims. That
code works. We would rather delete it.

## The ten requirements

| Requirement | Priority | What we build when it is missing |
|---|---|---|
| [exit-truth](#exit-truth) | Blocking | A shell wrapper that writes an exit-code sentinel file, and a poller for it |
| [replay-cursor](#replay-cursor) | Blocking | In-guest `tee` journals, a `tail -c +1 -f` replayer, byte-counting de-duplication |
| [detached-sessions](#detached-sessions) | Blocking | The same journal shim plus our own session registry, keyed by a tag we invent |
| [absence-definitive](#absence-definitive) | Blocking | A hand-maintained map from every error shape to "definitely gone" or "ask again later" |
| [stdin-total](#stdin-total) | Costly | A private FIFO fed by `tail -f`; "close stdin" implemented as killing the tail |
| [named-create](#named-create) | Costly | A second naming system in provider metadata, and a converger for duplicates our own retries created |
| [park-not-expire](#park-not-expire) | Costly | A heartbeat on every live command, and an auto-pause setting so a missed beat parks instead of kills |
| [honest-listing](#honest-listing) | Costly | The reaper stands down for that provider entirely; leaked sandboxes accumulate until a human intervenes |
| [egress-deny](#egress-deny) | Costly | A fail-open translation, and a doc telling the operator their "contained" environment is not |
| [url-or-nothing](#url-or-nothing) | Wanted | We report `:unsupported`, and the agent cannot tell a human where its preview is running |

### exit-truth

**We need** exactly one terminal event per command, carrying the process's
actual exit code, on the streaming path as well as the blocking one, and
distinguishable from a transport failure that ended the stream early.

**Because** a setup script that fails silently produces a sandbox that looks
provisioned and is not. Nobody finds out until the model says it cannot find
the repository, twenty minutes later, in front of a customer. An exit code
that is always `0` is worse than no exit code, because it is a lie we act on.

**Acceptance:** `sh -c 'exit 3'` reports 3 on both the blocking and streaming
paths, and a sandbox killed mid-command surfaces as a transport error rather
than exit 0.

### replay-cursor

**We need** a per-session output journal readable from byte zero or from a
cursor the platform hands back, with stdout and stderr kept distinct.

**Because** we redeploy while turns are running: the process reading a turn
dies, the turn does not. Rejoining must not duplicate or drop a byte, since
those bytes are being rendered into a transcript a human is reading right
now. A backend that replays "the last 64 KiB", starting mid-line, corrupts
that arithmetic silently.

Our own contract specifies replay-from-byte-zero purely because no platform
offers a cursor; callers then de-duplicate by counting bytes already
persisted per stream.

**Acceptance:** attach to a running session twice, once from byte zero and
once from a cursor, and the concatenated output is byte-identical to an
uninterrupted read.

### detached-sessions

**We need** spawn-as-detachable, list-sessions-on-a-sandbox, and
rejoin-by-id, as three first-class operations.

**Because** shipping our control plane must not kill in-flight turns, and
after an unplanned restart we need to discover what is still running before
deciding anything. Sessions are the unit of recovery.

**Acceptance:** kill the client mid-command, list sessions, rejoin by id, and
receive the terminal frame with the real exit code.

### absence-definitive

**We need** a documented statement of which responses mean a sandbox is
definitively gone, and a guarantee that a partition, a throttle, an expired
credential or a slow region never produces one of them.

**Because** a parked sandbox's disk is the agent's memory. Our reaper
reconciles the provider's listing against our database and destroys what the
provider says is untracked. If a blip reads as absence, we delete a
customer's work. This is not hypothetical. A control-plane partition on our
side once made nine live sandboxes look absent, and the next sweep destroyed
them.

**Acceptance:** during an induced control-plane outage, no endpoint returns
not-found for a sandbox that exists. Publish the list of statuses that are
safe to treat as definitive.

### stdin-total

**We need** writes to an exited process to return a distinct "already exited"
rather than a transport error, and closing stdin to send a real EOF, once, on
demand.

**Because** agent protocols are conversational: we write a turn's input to a
process that may be finishing as we write. The race is normal traffic, not an
edge case, so it has to be data rather than an exception. A stdin channel
that EOFs after every write cannot carry a multi-message protocol at all.

**Acceptance:** a `cat` reading stdin ends on close and only on close; a
write issued after exit returns *exited*, not a transport error.

### named-create

**We need** caller-supplied identity, and a create that returns the existing
sandbox when the name is taken instead of minting a second one.

**Because** idempotence under retry is the whole game for a control plane.
With server-assigned identity, a timed-out create leaves an orphan we are
paying for and cannot address, so we end up maintaining a second naming
system in provider metadata and reconciling the duplicates our own retries
produced.

**Acceptance:** two concurrent creates of the same name yield one sandbox and
two identical handles.

### park-not-expire

**We need** a pause or stop that keeps the filesystem at storage-only cost,
with no TTL that destroys. Where a TTL is unavoidable, expiry must park
rather than kill.

**Because** our cost model is "park everything idle", and the disk being
parked is what makes the next turn a continuation rather than a fresh start.
Destroy-on-TTL turns every long-running turn into a heartbeat treadmill, and
one missed beat into data loss.

**Acceptance:** park a sandbox, wait a week, resume, and read a file written
before the park.

### honest-listing

**We need** pagination that is explicit and terminating, and an error rather
than a `200` when a full account view cannot be produced.

**Because** our reaper destroys sandboxes that appear on the provider's side
and not on ours. A page that is silently short makes live sandboxes look
untracked. This is the one place where partial success is strictly more
dangerous than an outage: an outage makes us stand down, a short page makes
us act.

**Acceptance:** a listing interrupted server-side surfaces as an error, never
as a truncated set that looks whole.

### egress-deny

**We need** an empty allowlist that means nothing gets out, settable per
sandbox at creation, on every plan tier, without a support ticket.

**Because** the agent inside has credentials and is executing text written by
someone else. The network is the exfiltration path, and it is the control a
security review always asks about. Tier-gating it means the operators who
most need containment are the ones who cannot buy it.

**Acceptance:** an allowlist of exactly one host; every other destination
fails to connect, including DNS and raw IP.

### url-or-nothing

**We need** one HTTP endpoint per sandbox that a browser can open without a
platform credential, reported by the API, or a clear statement that the
platform has no such concept.

**Because** agents build things and then need to show a human. "Where is it
running?" is the most common question after a successful turn, and per-port
hostnames the orchestrator has to guess are worse than nothing: a URL that
does not resolve gets blamed on whoever handed it over.

**Acceptance:** serve on a port inside the sandbox, then open the reported
URL from a browser with no platform account.

## Where the four backends stand

Measured August 2026 through the adapters in this repository, against
then-current APIs and daemon versions. It is a snapshot, not a scorecard, and
several entries are probably already stale.

| Requirement | [Sprites](sprites.md) | [E2B](e2b.md) | [Daytona](daytona.md) | [Runner](runners.md) |
|---|---|---|---|---|
| exit-truth | No, exec reports 0 regardless | Yes | No, no exit code on session-command records | Yes |
| replay-cursor | Partial, replays the last 16 KiB starting mid-line | No, journaling shim plus tail replayer | Yes, journal replays from byte zero | Yes |
| detached-sessions | Yes | No, emulated by the adapter | Yes | Yes |
| absence-definitive | Undocumented | Undocumented | Undocumented | Yes, every offline shape is transient by construction |
| stdin-total | Yes | Yes | No, the FIFO EOFs after every write and has no close | Yes |
| named-create | Yes | No, names emulated via metadata | Yes | Yes |
| park-not-expire | Yes, scales to zero | Partial, pause preserves the disk but a TTL runs underneath | Yes, stop then archive to object storage | Yes |
| honest-listing | Yes, continuation tokens | Not measured | Not measured | Yes |
| egress-deny | Partial, translated fail-open | Yes | Yes, but tier-gated | No, by design, since the machine is the user's |
| url-or-nothing | Yes | No, per-port hostnames only | No | No |

The fourth backend is our own daemon ([self-hosted
runner](runners.md)), worth reading as an existence proof rather than a
comparison. It meets nearly all of this because we wrote both ends, which is
the only reason we know the list is implementable rather than merely
desirable.

## The rule underneath all ten

!!! note "Advertise or refuse, never pretend"

    An orchestrator can degrade gracefully around a missing capability. It
    cannot degrade around a capability that is claimed and then quietly does
    nothing.

A pause that silently returns a fresh disk is data loss. A network policy
accepted with a `200` and never enforced is a false security claim we pass on
to an operator. A guessed preview URL is a support ticket for someone else's
product.

The whole abstraction rests on this: each adapter declares a capability set,
and the lifecycle changes shape accordingly, so a backend that cannot park gets
destroy-on-idle rather than a fake park. That only works if "I don't support
this" is an answer the platform's API is willing to give.

## What we are not asking for

Naming the non-asks is half of making this a conversation rather than a wish
list.

- **A common wire format.** REST, gRPC, WebSocket, a vendor SDK, because we write
  the adapter. This page is about semantics, not shapes.
- **Images or provisioning.** We ship our own image per platform,
  deliberately, so that no provisioning logic is provider-specific.
- **Checkpoint and snapshot APIs.** Genuinely useful, currently optional, and
  we have shipped without them.
- **Tenancy, billing or region models.** The differences there have cost us
  nothing.
- **Feature parity with each other.** The capability set exists precisely so
  platforms can differ. Three honest, differently-shaped platforms beat three
  identical ones.

## Where this list is biased

It was written by one consumer with one workload, and it shows. We
over-specify sessions and streams because an agent turn is a long
conversation with a process, and under-specify scheduling, burst behaviour,
cold-start latency and everything a hundred-thousand-short-jobs workload
cares about. A genuinely neutral contract needs another kind of customer in
the room.

The capability vocabulary is also doing more work than it should.
`:suspend` currently means three different promises across our backends,
namely scale-to-zero, an explicit pause, and stopping processes in a
directory, and
they are not equivalent. If any of this became a shared specification, that
word would need splitting first.

## Testing a platform against it

`Fountain.SandboxConformanceCase` is a real test suite rather than a
checklist: an in-memory reference adapter passes it in full, and it pins
every semantic above, including the byte-exact replay test. The practical
route for a platform team is [adding a
provider](adding-a-sandbox-provider.md), whose verification ladder exists
because each rung caught something the previous one passed.
