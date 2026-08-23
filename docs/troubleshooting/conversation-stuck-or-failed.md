# A conversation is stuck or failed

This guide shows you how to find which step failed, and what to do about it.

## Read the stage events

Open the conversation's log view. Fountain records the progress of a new
sandbox as stage events. They are `provision`, `checkpoint_restore`,
`packages`, `network`, `clone`, `setup` and `turn`. The step that failed names
itself, and the event data holds the exit code.

**`packages`, `clone` or `setup` failed.** The cause is almost always the
environment's own configuration. A package that does not exist, a repository
the token cannot reach, or a setup script that exits non-zero. Fix the
environment, then prompt again.

**`provision` failed outright.** Fountain could not create the sandbox. The
provider is unhealthy, the token is invalid, or the user is at their quota for
concurrent sandboxes. Read [Sandbox errors](sandbox-errors.md).

**Stuck, with no failure.** A `running` conversation with no events usually
means the process on the sandbox side died and Fountain missed the exit.
Interrupt it, or send another prompt. A wake reattaches to the sandbox when
that sandbox still exists.

```bash
fountain conv show <conv-id>          # turn status, sandbox name
fountain conv interrupt <conv-id>     # stop the in-flight turn, keep the sandbox
fountain conv terminate <conv-id>     # destroy the sandbox, end the conversation
```

## The provider refused the model

A turn fails when the model provider refuses the agent's model. Fountain
records a `model` stage event with the refused id. The `turn` stage event holds
the provider's own message, and that message usually names a replacement.

```
The provider refused this agent's model (gemini-2.5-pro): This model
models/gemini-2.5-pro is no longer available to new users. Please update
your code to use models/gemini-3.1-pro-preview for the latest features
and improvements.
```

Open the agent. Set the model field to the replacement. Send the prompt again.
Each turn fails in the same way until that field changes.

The models Fountain lists are advice, not a set of permitted values. Fountain
sends any model id under a known provider to the runtime without a check. A
model released after the last deploy therefore works on the day it ships. A
provider can also retire a model at any time. A model that worked last month
can fail today.

## What the statuses mean

`failed` and `terminated` are the two terminal states. Fountain refuses a
further prompt.

`idle` with a *suspended* sandbox is the normal state at rest, and not an
error. The sandbox parks and scales to zero. The next prompt wakes it, and the
agent's memory is intact.

`idle` with a *destroyed* sandbox is what the max-lifetime ceiling leaves
behind, or what an explicit reap leaves. The next prompt provisions a fresh
sandbox. Fountain leaves the stored transcript alone, but the agent starts a
fresh session. Read [About conversations](../concepts/conversation.md), and
the full table in [Conversation states](../reference/conversation-states.md).

## The knock-on effect on quota

A crash in the middle of a provision leaves a `pending` or `starting` sandbox
row. That row counts against the user's quota, which is 5 concurrent sandboxes
by default.

The reaper runs each hour at :07 and releases a row that has been stuck for
more than 60 minutes. An admin can raise a user's cap from `/admin` at once.

The reaper logs one summary line for each run.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 destroyed=2 untracked=102 live=114
```

`parked` counts the idle sandboxes the reaper suspended. The reaper can undo
that, and it is not a teardown.

## Conversations from before August 2026

Stage status is reliable now. It was not always. On the default provider, a
setup script or a clone that failed could record as successful. The client
discarded the exit code and read a 0. See
[#880](https://github.com/BinaryBourbon/fountain/issues/880), fixed on
2026-08-23. For a conversation that ran before that date, read the logged
output. Do not trust its stage status.

## Related

- [Sandbox errors](sandbox-errors.md).
- [Conversation states](../reference/conversation-states.md).
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).
