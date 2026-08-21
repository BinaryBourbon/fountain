# Conversation states

The status values a conversation takes, what exists in each, and which
operations are legal. For what a conversation is, see
[About conversations](../concepts/conversation.md).

## Transitions

```
pending ---> running <---> idle
   |            |            |
   |            v            |
   +--------> failed <-------+

any non-terminal state ---> terminated
```

`idle` returns to `running` when a follow-up prompt arrives. Any non-terminal
state moves to `terminated` through
`POST /api/conversations/:id/terminate`.

## The states

| Status | What exists | What you can do | Terminal |
|---|---|---|---|
| `pending` | The conversation row and its resolved environment variable set. No sandbox yet | Terminate | No |
| `running` | A sandbox, and a turn in flight | Interrupt the turn, stream events, terminate | No |
| `idle` | A sandbox, no turn in flight. The sandbox may be live or suspended | Send a follow-up prompt, stream events, terminate | No |
| `failed` | The transcript and log events. The sandbox may already be gone | Read the transcript. Launch a new conversation | Yes |
| `terminated` | The transcript and log events | Read the transcript | Yes |

## The sandbox is not the status

A conversation's status describes the run. It does not tell you whether a
machine is currently powered on.

An `idle` conversation may have a live sandbox, a suspended one, or none at
all, depending on how long it has been idle and what the provider supports.

| Sandbox event | Trigger | Effect on status | Agent memory |
|---|---|---|---|
| Suspend | Idle for `SANDBOX_IDLE_TIMEOUT_MINUTES`, default 60 | None. Stays `idle` | Kept. The disk survives |
| Wake | The next prompt | `idle` to `running` | Kept |
| Destroy on ceiling | Running for `SANDBOX_MAX_LIFETIME_HOURS`, default 24 | None. Stays resumable | Lost. The next turn starts a fresh runtime session |
| Destroy on idle | Idle, on a provider without the `:suspend` capability | None | Lost |

Both bounds are set per instance. `0` disables either. See the
[configuration reference](../configuration.md).

## Warnings

A conversation in `failed` or `terminated` cannot be resumed. Launch a new one.

An interrupt applies to the turn in flight, not to the conversation. The
conversation returns to `idle` and remains usable.

Terminating is not reversible, and it destroys the sandbox along with the
agent's working memory. The transcript is kept.

A sandbox reclaimed at the max-lifetime ceiling leaves the conversation
resumable and the agent without its earlier context. Restate what matters on
the next turn.

## Where to go next

- [About conversations](../concepts/conversation.md).
- [API reference](../api.md), for the endpoints that cause each transition.
- [Configuration reference](../configuration.md), for the two timeouts.
