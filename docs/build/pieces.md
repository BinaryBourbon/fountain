# What each piece does

A chat app has three nouns: a contact, a thread, a message. Fountain has
[four primitives](../primitives.md), and they line up.

| In your UI | In Fountain | What it decides |
|---|---|---|
| the contact | **Agent** | which model and runtime answer, what the system prompt says, which skills and MCP servers exist |
| the thread | **Conversation** | one standing session, bound to the reserved channel `fountain:team` |
| the computer behind it | its **sandbox** | the filesystem, the shell, the network, the memory |
| what it is allowed to touch | **Environment** + **Vault** | packages, cloned repos, setup script, and the encrypted values injected at spawn |
| a message | a **turn** | one prompt and everything the agent did about it |

There is no fifth primitive for the team. A teammate *is* a conversation with
a channel binding, so anything you can do to a conversation you can do to a
teammate.

```
   Agent  "watchtower"                 the definition. Cheap. Reusable.
     │      runtime, model, system prompt, skills, mcp_servers
     │
     ├── Environment "watchtower-env"  the machine's shape: apt packages,
     │     repos to clone, setup script, encrypted secrets
     │
     └── Conversation ─ channel: fountain:team      ← the thread
           │  turns 1..n, a log feed, a status
           └── Sandbox                              ← the computer
                 Debian, a shell, the repos, the secrets as real env vars,
                 the runtime's session on disk
```

## One agent, one durable thread

`channel_id` is what arranges that. Sending to a channel that already has a
live conversation continues it, so your app needs no "create or find" dance
and no table of its own mapping rows to conversation ids.

The team is a reserved channel, `fountain:team`. Any other string is yours:

```ts
// a Slack channel, a Telegram chat, a row in your own product
await fountain.run(text, { agent: "watchtower", channelId: `slack:${channel}` });
```

Same behaviour, same sandbox per thread, without the team API at all.
[AG-UI](../integrations/openbot.md) binds one coworker channel to one
conversation this way, and [Buzz](../integrations/buzz.md) binds a Nostr
thread.

## What happens between Enter and the first word

```
  your app                     Fountain                       the sandbox
  ────────                     ────────                       ───────────
  POST /team/:id/messages ───▶ a turn in flight?  ─ yes ─▶ 400 conversation_busy
                               computer starting? ─ yes ─▶ 503 provisioning
                                     │ no
  ◀─── 202 {conversation_id}         │
       everything else arrives       ▼
       on the stream           wake it, or provision ─────▶ stage: reattach
                                     │                      stage: provision
                                     │                      stage: setup
                                     │                      env + vault become
                                     ▼                      real env vars here
                               prompt the runtime ────────▶ claude / codex / …
                                                                    │  ndjson
  SSE /api/team/stream ◀── redact ◀── persist ◀───────────────────── ┘
       stage: turn/started            every value Fountain
       …                              put in that machine,
       stage: turn/done               8 bytes or longer
```

**The 202 is not the answer.** `POST /messages` queues a turn and returns the
conversation id. Everything after that arrives on the stream, so an app
awaiting a reply is really awaiting stream events. The SDK's `Run` handle does
that waiting for you.

**Secrets enter at spawn, not at prompt.** The environment's values and the
vault's are merged (the vault wins on a key collision) and handed to the
sandbox as environment variables. Since they never reach the prompt, they
never reach the model's context, and no clever message can talk the model into
revealing them.

**Redaction is on the write path.** Every value of 8 bytes or more that
Fountain put into that sandbox is scrubbed out of persisted output. The
scrubbing happens on the single path every log event takes, rather than in the
client or as a rule the agent is asked to follow, so `env`, `set -x` and
`cat .env` all persist as `[REDACTED]`. A browser app can therefore offer a
"connect GitHub" button without much thought about the transcript.

## The computer's day

The sandbox has no equivalent in a stateless agent API, and its lifecycle is
what your empty states should be designed around.

```
  sandbox:  pending ──▶ starting ──▶ ready ──────────────▶ suspended
  presence: starting   starting     online / working       asleep
                                       │      ▲                │
                                       │      └── next message ┘
                                       │          wakes it, memory intact
                                       │
                                       │  24 h running (default)
                                       ▼
                                   terminated — the thread stays readable and
                                   resumable; the next turn starts a new
                                   computer, and a new memory
```

`ready` becomes `suspended` after 60 minutes with no turn (default).

Suspension is free and invisible. The disk survives, which keeps the runtime's
session alive, so message five never re-explains messages one through four.

The ceiling costs you that. A sandbox destroyed at the max-lifetime bound
loses its disk; the stored transcript is intact and the conversation still
resumes, but the agent's own memory of it is gone. Both bounds are
configurable (`SANDBOX_IDLE_TIMEOUT_MINUTES`, `SANDBOX_MAX_LIFETIME_HOURS`),
and `freshConversation()` is the deliberate version of the same thing: a new
session on the *same* disk.

## Who reads what

The two feeds a client uses are different on purpose.

| | `/api/team/stream` | `/api/conversations/:id/events` |
|---|---|---|
| covers | every teammate | one thread |
| carries | raw events + `conversation_id`, `agent_id` | events, and `blocks` on request |
| answers | *something happened, to whom* | *what was said* |
| you use it for | roster, typing dots, notifications, unread | rendering the thread |

A team UI wants both: one long-lived connection for the roster, and a read of
the open thread's feed. `blocks` keeps the second one from becoming a parser.
The server folds each runtime's dialect into `text`, `thinking`, `tool_use`,
`tool_result`, `init`, `result`, `error` and `raw`, so your renderer handles
eight kinds instead of four vendor formats.

## Where the multi-tenancy is

Every route is scoped to the key that called it. Across agents,
conversations, secrets, search and audit, a key sees its own account and
nothing else, and the scoping lives in the queries rather than in each
controller. So the second person to sign in gets their own roster, their own
computers and their own quota without you writing a line about it, and a
browser app holding one person's key cannot be talked into reaching anyone
else's teammates.

*Sharing* is the part you do not get for free. A teammate belongs to an
account, so a shared team room across several people remains your product's
problem. The usual answer is one Fountain account for the team, with your app
in front of it.

## Where to look next

- [The four primitives](../primitives.md) describes the same objects on their
  own terms.
- [Architecture](../architecture.md) covers what runs, and what breaks when a
  dependency is down.
- [Operations](../operations.md) is what to read when a computer is stuck.
- [A team chat, end to end](team-chat.md) is the code.
