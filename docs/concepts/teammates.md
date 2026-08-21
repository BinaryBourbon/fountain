# Agents as teammates

This page explains what a teammate is and why it is not a fifth primitive. For
the endpoints, see the [API reference](../api.md).

## What a teammate is

A teammate is an [Agent](agent.md) with one ongoing
[Conversation](conversation.md), bound to the reserved channel
`fountain:team`.

That is the whole mechanism. There is no team table and no teammate record. The
binding is the same one a Buzz channel uses through `channel_id`, pointed at a
reserved name.

The [team app](https://github.com/jhgaylor/fountain-team) lays those
conversations out like a messaging app, with the roster on the left and one
thread on the right, on `/api/team`.

## Why it works this way

A teammate needs exactly the properties a Conversation already has.

It needs to persist across messages, which a Conversation does. It needs a
machine that remembers what it did, which a suspended sandbox keeps on disk. It
needs to survive being idle overnight and wake on the next message, which
suspend and resume already do.

Adding a fifth primitive would have meant a second lifecycle to keep correct,
and every sandbox reclamation rule would have needed a teammate variant.
Binding a Conversation to a channel needed none of that.

## How it behaves

Adding an Agent to the team opens its conversation, which provisions the
sandbox.

A message is a follow-up turn on that conversation. A suspended or reclaimed
sandbox wakes on the next message as usual.

A terminated conversation is replaced by a fresh one under the same binding, so
the teammate stays reachable. Removing a teammate terminates the live
conversation and unbinds the Agent's conversations from the channel. The rows
stay in the ordinary conversation list.

"Details" on a thread opens the full transcript in the
[conversations app](https://github.com/jhgaylor/fountain-conversations),
with stages, tool calls and raw output.

## Three fields that look new and are not

When you add a teammate you can give it a name of its own, pick the Environment
its sandbox is built from, and attach a Vault.

None of that is new. They are the conversation's `title`, its per-launch
environment override, and its `vault_id`. The pickers only offer what the
Agent's `allowed_environment_ids` and `allowed_vault_ids` allow.

They belong to the teammate rather than to the sandbox. A fresh conversation
opened after the old one is terminated inherits all three.

## Schedules

A schedule is a cron that runs a teammate with a prompt. Cron times are UTC.

By default the prompt goes into the teammate's own conversation, as if you had
typed it, so the reply lands in the thread and in the teammate's working
memory.

Ticking **Run in a one-off computer** changes that. Each run opens a fresh
conversation on a new sandbox, using the same Agent, Environment and Vault the
teammate was added with, and leaves the thread alone. The run appears in the
conversation list like any other, and the schedule keeps a link to its last
one.

A schedule can be paused, edited, run on demand and deleted. If a run could not
be delivered, because the teammate was busy for half an hour or the sandbox
quota was full, the last error shows on the schedule.

Removing a teammate deletes its schedules.

## What a teammate is not

**Not a primitive.** Nothing in the API creates a teammate. You bind a
conversation to a channel.

**Not a shared inbox.** One Agent has one team conversation. Two people
messaging the same teammate are talking to the same thread and the same
machine.

**Not persistent memory.** The teammate's memory is the sandbox's disk. A
sandbox destroyed at the max-lifetime ceiling takes it, and the thread survives
without it. See [About conversations](conversation.md).

## Where to go next

- [About conversations](conversation.md), for the lifecycle underneath.
- [About agents](agent.md).
- [API reference](../api.md), for the team endpoints and schedules.
