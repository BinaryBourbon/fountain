# What Fountain needs from a sandbox platform

<!-- The ten requirement names are identifiers: exit-truth, replay-cursor,
     honest-listing, url-or-nothing and the rest. "Blocking" and "Costly"
     are the priority values. "blocking" and "streaming" name the two exec
     paths, and "naming system", "provisioning", "billing" and "scheduling"
     are Technical Names. STE exempts a Technical Name from Rule 3.4, and
     the linter has no vocabulary hook for that rule, so the exemption is
     declared for the page. Every other -ing form here was rewritten. -->
<!-- vale STE.IngForms = NO -->

This page is for a **sandbox platform team**. It lists the things Fountain had
to build itself, because no platform promised them. We order them by what
each one costs us, and each carries an acceptance test, so you can check the
agreement and not assume it.

The two pages beside this one have other audiences.
[The sandbox contract](sandbox-contract.md) is what the abstraction
guarantees a Fountain operator.
[Add a provider](adding-a-sandbox-provider.md) is the checklist for how to
write an adapter. This page is what we would ask for if we could ask.

Everything here is measurable against a real account, and an adapter in this
repository backs each claim. If one is wrong for your platform, to correct it
costs us less than to work around it.

## Why an agent turn is not a CI job

An agent turn runs for minutes or hours. It streams output that a person
watches in real time. It takes input mid-flight. The filesystem it leaves
behind **is the agent's memory**, because the next turn resumes on that disk.

Our control plane redeploys under turns that run, and it has to rejoin them.
Our reaper destroys sandboxes on the strength of what a provider's API says
exists.

Whoever built each platform we integrated aimed at a shorter, more disposable
unit of work, and each of them is excellent at that. The gaps below cluster in
one place, the seam between a command and the process that watches it.

Three of the four backends we ship can report that a command *ended*. None of
those three can reliably report whether it *worked*. Not one of the four can
tell us where in a stream we stopped.

So we wrote the contract down, as a behaviour, an error taxonomy and an
executable conformance suite. Then we made three hosted platforms pass it, and
built the absent pieces inside their sandboxes with shell shims. That code
works. We would rather delete it.

## The ten requirements

| Requirement | Priority | What we build when it is absent |
|---|---|---|
| [exit-truth](#exit-truth) | Blocking. | A shell wrapper that writes an exit-code sentinel file, and a poller for it. |
| [replay-cursor](#replay-cursor) | Blocking. | In-guest `tee` journals, a `tail -c +1 -f` replayer, and de-duplication by byte count. |
| [detached-sessions](#detached-sessions) | Blocking. | The same journal shim, and our own session registry, keyed by a tag we invent. |
| [absence-definitive](#absence-definitive) | Blocking. | A map we maintain by hand, from each error shape to "definitely gone" or "ask again later". |
| [stdin-total](#stdin-total) | Costly. | A private FIFO that `tail -f` feeds. "Close stdin" becomes a kill of the tail. |
| [named-create](#named-create) | Costly. | A second naming system in provider metadata, and a converger for the duplicates our own retries created. |
| [park-not-expire](#park-not-expire) | Costly. | A heartbeat on each live command, and an auto-pause setting, so a beat we miss parks the sandbox and does not kill it. |
| [honest-listing](#honest-listing) | Costly. | The reaper stands down for that provider entirely. Leaked sandboxes then pile up until a person steps in. |
| [egress-deny](#egress-deny) | Costly. | A translation that fails open, and a doc that tells the operator their "contained" environment is not. |
| [url-or-nothing](#url-or-nothing) | Wanted. | We report `:unsupported`, and the agent cannot tell a person where its preview runs. |

### exit-truth

**We need** exactly one terminal event for each command. It must carry the
process's true exit code. It must arrive on the streaming path as well as on
the blocking one. We must be able to tell it apart from a transport failure
that ended the stream early.

**Because** a setup script that fails without a sound produces a sandbox that
looks provisioned and is not. Nobody finds out until the model says it cannot
find the repository, twenty minutes later, in front of a customer. An exit
code that is always `0` is worse than no exit code, because it is a lie we act
on.

**Acceptance.** `sh -c 'exit 3'` reports 3 on the blocking path and on the
streaming path. A sandbox killed mid-command surfaces as a transport error,
and not as exit 0.

### replay-cursor

**We need** an output journal for each session. We must be able to read it
from byte zero, or from a cursor the platform hands back. It must keep stdout
and stderr apart.

**Because** we redeploy while turns run. The process that reads a turn dies,
and the turn does not. To rejoin must duplicate no byte and drop no byte,
because those bytes go into a transcript that a person reads right now. A
backend that replays "the last 64 KiB" and starts mid-line corrupts that
arithmetic without a sound.

Our own contract specifies replay from byte zero purely because no platform
offers a cursor. A caller then de-duplicates by a count of the bytes it
already persisted for each stream.

**Acceptance.** Attach to a session that runs twice, once from byte zero and
once from a cursor. The two outputs, concatenated, are byte-identical to one
uninterrupted read.

### detached-sessions

**We need** three first-class operations. Spawn as detachable. List the
sessions on a sandbox. Rejoin one by id.

**Because** a deploy of our control plane must not kill a turn in flight.
After a restart nobody planned, we must discover what still runs before we
decide the next move. A session is the unit of recovery.

**Acceptance.** Kill the client mid-command. List the sessions. Rejoin by id,
and receive the terminal frame with the real exit code.

### absence-definitive

**We need** a documented statement of which responses mean a sandbox has
definitively gone. We also need a guarantee that a partition, a throttle, an
expired credential or a slow region never produces one of them.

**Because** a parked sandbox's disk is the agent's memory. Our reaper
reconciles the provider's list against our database, then destroys whatever
the provider lists and our database does not. If a blip reads as absence, we
delete a customer's work.

That is not hypothetical. A control-plane partition on our side once made nine
live sandboxes look absent, and the next sweep destroyed them.

**Acceptance.** During an induced control-plane outage, no endpoint returns
not-found for a sandbox that exists. Publish the list of statuses that are
safe to treat as definitive.

### stdin-total

**We need** a write to a process that exited to return a distinct "already
exited", and not a transport error. We also need a close of stdin to send a
real EOF, once, on demand.

**Because** an agent protocol is conversational. We write a turn's input to a
process that can end as we write. That race is normal traffic, and not an edge
case, so it has to be data and not an exception. A stdin channel
that sends EOF after each write cannot carry a protocol of many messages at
all.

**Acceptance.** A `cat` that reads stdin ends on the close, and on nothing
else. A write issued after the exit returns *exited*, and not a transport
error.

### named-create

**We need** identity that the caller supplies. A create against a name that
somebody took must return the sandbox that exists, and not mint a second one.

**Because** idempotence under retry is the whole game for a control plane.
With identity the server assigns, a create that times out leaves an orphan
that we pay for and cannot address. So we end up with a second naming system
in provider metadata, and we reconcile the duplicates our own retries
produced.

**Acceptance.** Two concurrent creates of the same name yield one sandbox and
two identical handles.

### park-not-expire

**We need** a pause or a stop that keeps the filesystem at storage-only cost,
and no TTL that destroys. Where a TTL is unavoidable, an expiry must park the
sandbox and not kill it.

**Because** our cost model is "park everything idle". The disk we park is what
makes the next turn a continuation, and not a fresh start. Destroy-on-TTL
turns each long turn into a heartbeat treadmill, and one beat we miss into
data loss.

**Acceptance.** Park a sandbox. Wait a week. Resume it, and read a file
written before the park.

### honest-listing

**We need** pagination that is explicit and that terminates. When you cannot
produce a full account view, we need an error, and not a `200`.

**Because** our reaper destroys a sandbox that appears on the provider's side
and not on ours. A page that is quietly short makes a live sandbox look
untracked.

This is the one place where partial success is strictly more dangerous than an
outage. An outage makes us stand down. A short page makes us act.

**Acceptance.** A list that the server interrupts surfaces as an error. It
never surfaces as a truncated set that looks whole.

### egress-deny

**We need** an empty allowlist that means nothing gets out. We must be able to
set it for each sandbox at creation, on each plan tier, with no support
ticket.

**Because** the agent inside holds credentials, and executes text that
somebody else wrote. The network is the exfiltration path, and it is the
control that a security review always asks about. To gate it by tier means the
operators who most need containment are the ones who cannot buy it.

**Acceptance.** An allowlist of exactly one host. Each other destination fails
to connect, and that includes DNS and a raw IP.

### url-or-nothing

**We need** one HTTP endpoint for each sandbox that a browser can open with no
platform credential, reported by the API. Or we need a clear statement that
the platform has no such concept.

**Because** an agent builds things, then needs to show a person. After a turn
that worked, the most common question is where the thing now runs. A hostname for
each port, which the orchestrator has to guess, is worse than nothing. A URL
that does not resolve gets blamed on whoever handed it over.

**Acceptance.** Serve on a port inside the sandbox. Then open the reported URL
from a browser with no platform account.

## Where the four backends stand

We measured this in August 2026, through the adapters in this repository,
against the APIs and daemon versions of that moment. It is a snapshot, and not
a scorecard. Several entries are probably stale already.

| Requirement | [Sprites](sprites.md) | [E2B](e2b.md) | [Daytona](daytona.md) | [Runner](runners.md) |
|---|---|---|---|---|
| exit-truth | Yes. | Yes. | No. A session-command record carries no exit code. | Yes. |
| replay-cursor | Partial. It replays the last 16 KiB, and starts mid-line. | No. We ship a journal shim and a tail replayer. | Yes. The journal replays from byte zero. | Yes. |
| detached-sessions | Yes. | No. The adapter emulates them. | Yes. | Yes. |
| absence-definitive | Undocumented. | Undocumented. | Undocumented. | Yes. Each offline shape is transient by construction. |
| stdin-total | Yes. | Yes. | No. The FIFO sends EOF after each write, and has no close. | Yes. |
| named-create | Yes. | No. Metadata emulates the names. | Yes. | Yes. |
| park-not-expire | Yes. It scales to zero. | Partial. A pause keeps the disk, and a TTL runs underneath. | Yes. It stops, then archives to object storage. | Yes. |
| honest-listing | Yes, with continuation tokens. | Not measured. | Not measured. | Yes. |
| egress-deny | Partial. The translation fails open. | Yes. | Yes, and the tier gates it. | No, by design. The machine is the user's. |
| url-or-nothing | Yes. | No. It has a hostname for each port, and no more. | No. | No. |

One entry here was wrong for three months. This table said Sprites failed
exit-truth, because each command we ran through it reported 0. The platform
sent the true code every time. Our Elixir client read the one-byte field as
four bytes, matched no frame, and reported a 0 that nobody had sent. See
[#880](https://github.com/BinaryBourbon/fountain/issues/880).

Read that as a warning about this table. We measure each platform through our
own adapter, so every row says something about the adapter as well as the
platform. A row that reports a failure is the row to distrust first.

The fourth backend is our own daemon, the
[self-hosted runner](runners.md). Read it as an existence proof, and not as a
comparison. It meets nearly all of this because we wrote both ends. That is
the only reason we know this list is possible to implement, and not merely
desirable.

## The rule under all ten

!!! note "Advertise or refuse, never pretend"

    An orchestrator can degrade around a capability that is absent.
    It cannot degrade around a capability that you claim and that then quietly
    does nothing.

A pause that quietly returns a fresh disk is data loss. A network policy you
accept with a `200` and never enforce is a false security claim that we pass
on to an operator. A preview URL that somebody guessed is a support ticket for
another product.

The whole abstraction rests on this. Each adapter declares a capability set,
and the lifecycle changes shape to match. A backend that cannot park then gets
destroy-on-idle, and not a fake park. That works only when "I do not support
this" is an answer the platform's API will give.

## What we do not ask for

To name the non-asks is half of what makes this a conversation, and not a wish
list.

- **A common wire format.** REST, gRPC, WebSocket or a vendor SDK, because we
  write the adapter. This page is about semantics, and not shapes.
- **Images, or provisioning.** We ship our own image for each platform,
  deliberately, so that no provision logic belongs to one provider.
- **Checkpoint and snapshot APIs.** They are genuinely useful. They are
  optional today, and we shipped without them.
- **Tenancy, billing or region models.** The differences there have cost us
  nothing.
- **Parity with each other.** The capability set exists precisely so that
  platforms can differ. Three honest platforms with three shapes beat three
  identical ones.

## The bias in this list

One consumer with one workload wrote it, and it shows.

We over-specify sessions and streams, because an agent turn is a long
conversation with a process. We under-specify scheduling, burst behaviour,
cold-start latency, and everything else that a hundred-thousand-short-jobs
workload cares about. A neutral contract needs another kind of customer
in the room.

The capability vocabulary also does more work than it should. `:suspend` today
means three different promises across our backends. Those are scale-to-zero,
an explicit pause, and a stop of the processes in a directory. They are not
equivalent. If any of this became a shared specification, somebody would have
to divide that word first.

## How to test a platform against it

`Managoat.Sandbox.ConformanceCase` is a real test suite, and not a checklist.
An in-memory reference adapter passes it in full, and it pins each semantic
above, the byte-exact replay test with them.

The practical route for a platform team is
[Add a provider](adding-a-sandbox-provider.md). Its verification ladder exists
because each rung caught something the rung before it passed.

<!-- vale STE.IngForms = YES -->
