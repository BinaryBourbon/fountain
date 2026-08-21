# About conversations

This page explains what a Conversation is and what happens to its sandbox over
time. For the state table, see
[Conversation states](../reference/conversation-states.md). For the endpoints,
see the [API reference](../api.md).

## What a conversation is

A Conversation is one run of an [Agent](agent.md) inside a sandboxed machine.

It starts with a prompt and continues over turns. It has a transcript, a stream
of log events, and a status. It is the only primitive that costs money while it
exists, because it is the only one with a machine attached.

## Why it exists

The other three primitives are configuration and could have been one object
with three sections. The Conversation is why they are not.

A Conversation is the point where the three are resolved together into a
running machine. It picks an Agent, may override that Agent's Environment, and
may attach a Vault, and it does all three at launch rather than at
configuration time. That is what lets one Agent serve staging and production,
one Environment serve twenty agents, and one Vault be borrowed by any of them.

## How it works

Launching a Conversation resolves the full environment variable set and asks a
sandbox provider for a machine.

```
POST /api/conversations
        |
        v
resolve agent -> environment (or the per-launch override)
        |
        v
merge environment secrets with vault secrets   (vault wins)
        |
        v
provision a sandbox, write skills and the system prompt
        |
        v
run the turn, stream log events over SSE
```

A follow-up prompt runs another turn on the same machine. A running turn can be
interrupted, and the whole conversation can be ended early.

Log events stream in real time over
`GET /api/conversations/:id/stream`. Add `?blocks=true` and the server does the
runtime-dialect parsing, so a client never has to.

## The sandbox does not live forever, and that is two rules

Both bounds act on the sandbox. Neither ends the Conversation, which stays
resumable either way.

**Idle suspends.** After 60 minutes with no turn activity, by default, the
sandbox is suspended. It scales to zero and costs nothing while parked. The
next prompt wakes it with the agent's memory intact, because the runtime keeps
its session on the sandbox's disk and a suspended sandbox keeps its disk.

**A ceiling destroys.** At 24 hours of continuous running, by default, the
sandbox is destroyed. Disk and all. The stored transcript survives and the
conversation stays resumable, but the next turn starts a fresh runtime session,
so the agent answers without the earlier ones. Expect to restate context after
a ceiling reclaim.

The difference matters. Suspend keeps the agent's memory. The ceiling does not.

Self-hosters can widen or disable both with
`SANDBOX_IDLE_TIMEOUT_MINUTES` and `SANDBOX_MAX_LIFETIME_HOURS`, where `0`
disables. See the
[configuration reference](../configuration.md).

Not every sandbox provider can suspend. A provider that does not advertise the
capability destroys on idle rather than faking a park, because resuming with a
fresh disk would be silent loss of the agent's memory. See
[the sandbox contract](../integrations/sandbox-contract.md).

## What a conversation is not

**Not the transcript.** The transcript is stored and outlives the sandbox. The
Conversation is the run.

**Not a chat session in a UI.** Fountain's own console does not render
conversations. Watching one work happens in the
[conversations app](https://github.com/jhgaylor/fountain-conversations),
which is a separate application on `/api`.

**Not a sandbox you manage.** You never create, name or address a sandbox. It
is provisioned when the Conversation starts and reclaimed on the rules above.

## When to use something else

Use a [teammate](teammates.md) when you want one ongoing thread with an agent
rather than a run per task. A teammate is still a Conversation, bound to a
reserved channel.

Use a schedule when the run should happen without you. See the
[API reference](../api.md).

## Where to go next

- [Conversation states](../reference/conversation-states.md), the state table.
- [Agents as teammates](teammates.md).
- [Architecture](../architecture.md), for what runs where.
- [The guided tour](../tour.md), which runs one end to end.
