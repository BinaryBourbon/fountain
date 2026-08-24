# About conversations

This page explains what a Conversation is, and what happens to its sandbox
over time. For the state table, read
[Conversation states](../reference/conversation-states.md). For the endpoints,
read the [API reference](../api.md).

## What a conversation is

A Conversation is one run of an [Agent](agent.md) in a sandboxed machine.

It starts with a prompt and continues over turns. It has a transcript, a
stream of log events, and a status. It is the only primitive that costs money
while it exists, because it is the only one with a machine attached.

## Why it exists

The other three primitives are configuration. They could have been one object
with three sections. The Conversation is the reason they are not.

At the Conversation, Fountain resolves all three together into a machine that
runs. The Conversation picks an Agent. It can override that Agent's
Environment, and it can attach a Vault. It does all three at launch, and not at
configuration time.

That is what lets one Agent serve staging and production. It lets one <!-- vale disable-line STE.IngForms -->
Environment serve twenty agents. It lets any of them borrow one Vault.

## How it works

A launch resolves the full environment variable set, then asks a sandbox
provider for a machine.

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

The same machine runs another turn for a follow-up prompt. You can interrupt a
turn that runs, and you can end the whole conversation early.

Log events stream in real time over
`GET /api/conversations/:id/stream`. Add `?blocks=true` and the server parses
the runtime dialect, so a client never has to.

## The sandbox does not live forever, and that is two rules

Both bounds act on the sandbox. Neither one ends the Conversation, which stays
resumable either way.

**Idle suspends.** By default, 60 minutes with no turn activity suspends the
sandbox. It scales to zero, and a parked sandbox costs nothing. The next
prompt wakes it, and the agent's memory is intact. The runtime keeps its
session on the sandbox's disk, and a suspended sandbox keeps its disk.

**Nothing stops a busy sandbox.** A conversation that keeps its sandbox busy
keeps it up. There is no ceiling on a continuous run by default. A
self-hoster can set one with `SANDBOX_MAX_LIFETIME_HOURS`. When set, to cross
it destroys an ephemeral sandbox, and the disk goes with it. The stored
transcript survives and the conversation stays resumable. The next turn
starts a fresh runtime session, so the agent answers without the earlier
turns. Fountain parks a persistent home instead.

The difference matters. Suspend keeps the agent's memory. A destroy does
not.

A self-hoster can widen or stop the idle bound with
`SANDBOX_IDLE_TIMEOUT_MINUTES`, and a `0` stops it. Read the
[configuration reference](../configuration.md).

Not every sandbox provider can suspend. A provider that does not advertise the
capability destroys on idle. It does not fake a park, because a resume with a
fresh disk would lose the agent's memory without a sound. Read
[the sandbox contract](../integrations/sandbox-contract.md).

## What a conversation is not

**Not the transcript.** Fountain stores the transcript, and the transcript
outlives the sandbox. The Conversation is the run.

**Not a chat session in a UI.** Fountain's own console renders no
conversations. You watch one work in the
[conversations app](https://github.com/jhgaylor/fountain-conversations),
a separate application on `/api`.

**Not a sandbox you manage.** You never create, name or address a sandbox.
Fountain provisions it when the Conversation starts, and reclaims it on the
rules above.

## When to use something else

Use a [teammate](teammates.md) when you want one thread with an agent that
continues, and not one run for each task. A teammate is still a Conversation,
bound to a reserved channel.

Use a schedule when the run must happen without you. Read the
[API reference](../api.md).

## Where to go next

- [Conversation states](../reference/conversation-states.md), the state table.
- [Agents as teammates](teammates.md).
- [Architecture](../architecture.md), for what runs where.
- [The guided tour](../tour.md), which runs one from start to finish.
