# What each piece does

A chat app has three nouns: a contact, a thread, a message. Fountain has
[four primitives](../primitives.md). They line up, and knowing which is which
is most of what you need to reason about the app you are building.

| In your UI | In Fountain | What it decides |
|---|---|---|
| the contact | **Agent** | which model and runtime answer, what the system prompt says, which skills and MCP servers exist |
| the thread | **Conversation** | one standing session, bound to the reserved channel `fountain:team` |
| the computer behind it | its **sandbox** | the filesystem, the shell, the network, the memory |
| what it is allowed to touch | **Environment** + **Vault** | packages, cloned repos, setup script, and the encrypted values injected at spawn |
| a message | a **turn** | one prompt and everything the agent did about it |

There is no fifth primitive for the team. A teammate *is* a conversation with
a channel binding, which is why anything you can do to a conversation you can
do to a teammate.

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

## The channel binding is the whole trick

`channel_id` is what makes one agent equal one durable thread. Sending to a
channel that already has a live conversation continues it; there is no
"create or find" dance in your app, and no table of your own mapping rows to
conversation ids.

The team is a reserved channel, `fountain:team`. Any other string is yours:

```ts
// a Slack channel, a Telegram chat, a row in your own product
await fountain.run(text, { agent: "watchtower", channelId: `slack:${channel}` });
```

Same behaviour, same sandbox-per-thread, without the team API at all. This is
how [AG-UI](../integrations/openbot.md) binds one coworker channel to one
conversation, and how [Buzz](../integrations/buzz.md) binds a Nostr thread.

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

Three things in that picture are worth carrying around:

**The response is 202, not the answer.** `POST /messages` queues a turn and
returns the conversation id. Everything after that arrives on the stream. An
app that awaits a reply is really awaiting stream events — which is what the
SDK's `Run` handle does for you.

**Secrets enter at spawn, not at prompt.** The environment's values and the
vault's are merged (the vault wins on a key collision) and handed to the
sandbox as environment variables. They are not in the prompt, so they are not
in the model's context, so they cannot be argued out of the model by a clever
message.

**Redaction is on the write path.** Every value of 8 bytes or more that
Fountain put into that sandbox is scrubbed out of persisted output. Not
best-effort in the client, not a rule the agent is asked to follow — the
single path every log event takes. `env`, `set -x` and `cat .env` all persist
as `[REDACTED]`. It is why a browser app can offer a "connect GitHub" button
without you having to think very hard about the transcript.

## The computer's day

The sandbox is the piece that has no equivalent in a stateless agent API, and
its lifecycle is the thing to design your empty states around.

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

Suspension is free and invisible: the disk survives, so the runtime's session
survives, so message five does not need to re-explain messages one through
four. That is the difference between a bot you chat with and a colleague you
leave a note for.

The ceiling is not. A sandbox destroyed at the max-lifetime bound loses the
disk; the stored transcript is intact and the conversation is still resumable,
but the agent's own memory of it is gone. Both bounds are configurable
(`SANDBOX_IDLE_TIMEOUT_MINUTES`, `SANDBOX_MAX_LIFETIME_HOURS`), and
`freshConversation()` is the deliberate version of the same thing: a new
session, on the *same* disk.

## Who reads what

The two feeds a client uses are different on purpose.

| | `/api/team/stream` | `/api/conversations/:id/events` |
|---|---|---|
| covers | every teammate | one thread |
| carries | raw events + `conversation_id`, `agent_id` | events, and `blocks` on request |
| answers | *something happened, to whom* | *what was said* |
| you use it for | roster, typing dots, notifications, unread | rendering the thread |

A team UI wants both: one long-lived connection for the roster, and a read of
the open thread's feed. `blocks` is what keeps the second one from becoming a
parser — the server folds each runtime's dialect into `text`, `thinking`,
`tool_use`, `tool_result`, `init`, `result`, `error`, `raw`, and your renderer
handles eight kinds instead of four vendor formats.

## Where the multi-tenancy is

Every route is scoped to the key that called it. Agents, conversations,
secrets, search, audit — a key sees its own account and nothing else, and the
scoping lives in the queries rather than in each controller. For your app that
means the second person to sign in gets their own roster, their own computers
and their own quota without you writing a line about it — and that a browser
app holding one person's key cannot be talked into reaching anyone else's
teammates.

What you do not get for free is *sharing*. A teammate belongs to an account.
A shared team room across several people is your product's problem — the usual
answer being one Fountain account for the team, with your app in front of it.

## Where to look next

- [The four primitives](../primitives.md) — the same objects, described on
  their own terms.
- [Architecture](../architecture.md) — what runs, and what breaks when a
  dependency is down.
- [Operations](../operations.md) — what to do when a computer is stuck.
- [A team chat, end to end](team-chat.md) — the code.
