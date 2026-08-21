# A conversation is stuck or failed

This guide shows you how to find which step failed and what to do about it.

## Read the stage events

Open the conversation's log view. Provisioning progress is recorded as stage
events, `provision`, `checkpoint_restore`, `packages`, `network`, `clone`,
`setup`, `turn`. The failing step names itself, with the exit code in the event
data.

**`packages`, `clone` or `setup` failed.** Almost always the environment's own
configuration. A package that does not exist, a repository the token cannot
reach, a setup script exiting non-zero. Fix the environment and prompt again.

**`provision` failed outright.** The sandbox could not be created. The provider
is unhealthy, the token is invalid, or the user is at their concurrent-sandbox
quota. See [Sandbox errors](sandbox-errors.md).

**Stuck with no failure.** A conversation `running` with no events arriving
usually means the sandbox-side process died and the exit was missed. Interrupt
it, or just send another prompt, because waking reattaches to the existing
sandbox when it still exists.

```bash
fountain conv show <conv-id>          # turn status, sandbox name
fountain conv interrupt <conv-id>     # stop the in-flight turn, keep the sandbox
fountain conv terminate <conv-id>     # destroy the sandbox, end the conversation
```

## What the statuses mean

`failed` and `terminated` are the two terminal states, and a further prompt is
refused.

`idle` with a *suspended* sandbox is the normal resting state rather than an
error. The sandbox is parked, scaled to zero, and the next prompt wakes it with
the agent's memory intact.

`idle` with a *destroyed* sandbox is what the max-lifetime ceiling, or an
explicit reap, leaves behind. The next prompt provisions fresh and the stored
transcript is unaffected, but the agent starts a fresh session. See
[About conversations](../concepts/conversation.md) and the full table in
[Conversation states](../reference/conversation-states.md).

## Quota knock-on

A crash mid-provision leaves a `pending` or `starting` sandbox row that counts
against the user's quota, default 5 concurrent.

The reaper runs hourly at :07 and releases rows stuck longer than 60 minutes.
An admin can raise a user's cap from `/admin` immediately.

The reaper logs one summary line per run.

```bash
kubectl logs -n fountain -l app=fountain --since=2h | grep 'reaper:'
# reaper: released=0 parked=1 expired=0 destroyed=2 untracked=102 live=114
```

`parked` is the reaper suspending idle sandboxes, which is reversible
bookkeeping rather than a teardown.

## One trap worth knowing

On the default provider, a failed setup script or clone can record as
successful, because the exec transport reports exit code 0 for every command
([#880](https://github.com/BinaryBourbon/fountain/issues/880), open). Read the
logged output rather than trusting the stage status when a conversation starts
in a state you did not expect.

## Related

- [Sandbox errors](sandbox-errors.md).
- [Conversation states](../reference/conversation-states.md).
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).
