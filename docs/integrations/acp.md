# `fountain acp`, the ACP agent reference

`fountain acp` is the one process every ACP client of Fountain spawns:
[editors](editors.md) (Zed and friends), [OpenClaw](openclaw.md), and the
[Buzz](buzz.md) harness all speak the
[Agent Client Protocol](https://agentclientprotocol.com) to it over stdio, and
it drives a conversation running in a Fountain sandbox. Those three pages cover
*setting up the client*. This page is the reference for the adapter itself,
covering what it accepts, what it does with it, and what it deliberately
ignores, so
they do not each restate it.

**What it is, and is not.** A control surface for a conversation that runs on
your Fountain instance: open it, prompt it, watch it, interrupt it, reopen it
tomorrow. It has no access to the machine it runs on beyond its own stdio and
the CLI's credentials. Every path it reports is inside the sandbox.

## Invocation

```bash
fountain acp --agent <name-or-id> [--vault <name-or-id>] [--environment <name-or-id>] [--log-level debug]
```

| Flag | Meaning |
|---|---|
| `--agent` | **Required in practice.** The Fountain agent every session runs. ACP has no field for it, so it is configured per process, one client entry per agent you want to reach. |
| `--vault` | A vault attached to every conversation this process opens. Vault values override the agent's environment, so this is where per-entry secrets belong, such as an identity the agent posts under. Two entries on the same agent with different vaults stay separate. |
| `--environment` | Provision every conversation from this environment instead of the agent's own, so one agent config runs under several environments with one entry each. The vault still wins on key collision. When the agent sets `allowed_environment_ids`, the environment must be on that list. |
| `--log-level` | stderr verbosity: `debug`, `info` (default), `warn`, `error`. |
| `--profile` | Which saved CLI credentials to use (global flag). |

**Credentials** are the CLI's: `FOUNTAIN_API_KEY` / `FOUNTAIN_BASE_URL` in the
environment, else the profile `fountain auth login` saved. There is no login
inside the protocol. `authenticate` verifies what the CLI already holds and
its one advertised method just says "run `fountain auth login`". A hosted
Buzz harness gets a freshly minted, sprite-scoped key in its environment for
exactly this reason.

**stdout is the protocol and nothing else; diagnostics go to stderr.** That is
where your client's agent-server log will show them, and the first place to
look when something is wrong.

## The protocol surface

Protocol version **1**, negotiated down to the client's if lower. `agentInfo`
is `fountain` with the CLI's version.

| Method | What Fountain does |
|---|---|
| `initialize` | Capability handshake. The client's own capabilities (`fs`, terminals) are logged and unused, because this agent works on a sandbox filesystem rather than yours. |
| `authenticate` | Verifies the CLI's saved credentials against the instance. Advertised only when none are held. |
| `session/new` | Resolves `--agent`, refuses an agent whose runtime does not speak ACP (today: `gemini`, [#659](https://github.com/BinaryBourbon/fountain/issues/659)), and opens a conversation. **The ACP session id *is* the conversation id**, as below. Responds with the agent's model as the single available model. |
| `session/prompt` | Sends the turn (text and images; other blocks are dropped with a warning, an all-unusable prompt is refused) and streams the conversation's ACP output back as `session/update` notifications until the turn ends. |
| `session/cancel` | Interrupts the running turn. |
| `session/load` | Reopens a conversation this process did not start: the stored `session/update` history is replayed **before** the response, as the spec requires. |
| `session/set_model` | Not implemented. The model belongs to the Fountain agent; changing it here would change every conversation on that agent. |
| `session/request_permission` (agent → client) | Not forwarded yet, because sandboxed runtimes run under their own permission mode ([#643](https://github.com/BinaryBourbon/fountain/issues/643), [#708](https://github.com/BinaryBourbon/fountain/issues/708)). |

Advertised capabilities: `loadSession: true`; prompt `image: true`,
`audio: false`, `embeddedContext: false` (the client may not inline a local
file, which would be context about a machine the agent cannot see).

`cwd` and `mcpServers` on `session/new` are logged and ignored: the sandbox
clones its own checkout, and a Fountain agent carries its own MCP configuration
to the sandbox. Fountain may *add* MCP servers of its own to a session, and the
Buzz publish tools are injected this way, but never the client's.

### The session id is the conversation id

`session/new` returns the Fountain conversation id as the ACP `sessionId`
([ADR 0015](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md),
[#699](https://github.com/BinaryBourbon/fountain/issues/699)). That is what
makes `session/load` work across processes and days: an editor hands back an id
from last week and it resolves to a real conversation, not to a map that died
with the process that minted it. It is also why the same id shows up in the web
UI, `fountain conv`, and the audit trail.

### What streams back

The sandbox runtime already speaks ACP to Fountain
([ADR 0014](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0014-agent-client-protocol.md)),
so the adapter is a proxy, not a translator: `agent_message_chunk`,
`agent_thought_chunk`, `tool_call`, `tool_call_update` and friends are
forwarded as they arrive, with the `sessionId` rewritten to yours. Two
adjustments follow, both about the machine boundary.

- **`tool_call.locations` are moved to `_meta["fountain.sandboxLocations"]`.**
  They name files in the sandbox; left in place an editor would open (or fail
  to open) paths on your machine.
- **Stop reasons come from the sandbox** (`end_turn`, `refusal`, `cancelled`,
  …). What the sandbox has no vocabulary for, such as never having
  provisioned, being reclaimed mid-turn, or the conversation being terminated,
  is reported as a
  JSON-RPC error rather than dressed up as "the agent finished".

A dropped SSE connection is not a lost turn: the server closes an idle stream
after 60 s and the adapter reconnects and resumes from where it left off.

### `_meta` extensions on `session/new`

Out-of-band fields a chat harness sends; anything else in `_meta` is ignored.

| Field | Meaning |
|---|---|
| `channelId` | Names the external channel this session serves. With it, `session/new` **resumes** the conversation already bound to that channel for this user + agent + vault (same conversation, same sandbox, same runtime session, with a fresh ACP id from the client's side), so a harness that forgets its sessions on restart lands back where it was ([#774](https://github.com/BinaryBourbon/fountain/issues/774)). Without it every `session/new` is a new conversation. |
| `freshSession` | With `channelId`, skip the resume this once. Unbind the current conversation (it keeps running and is retired like any other idle one) and open a new one as the binding. This is what a Buzz owner's `!rotate` turns into ([#788](https://github.com/BinaryBourbon/fountain/pull/788)). Ignored without `channelId`. |

The same knobs exist on the API as `channel_id` / `fresh` on
`POST /api/conversations`.

## Lifecycle, sandboxes, and what survives

- **A turn ends when the conversation says so**, at the terminal `turn` stage
  event with its stop reason, not when output goes quiet.
- **An idle sandbox is suspended, not lost.** The next prompt resumes it. A
  sandbox reclaimed at its maximum lifetime, or one that fails to reattach, is
  reported as an error on the turn that hit it; prompt again to provision a
  fresh one. The transcript is untouched either way and `session/load` replays
  it, but the agent's own working memory in the sandbox is gone
  ([#649](https://github.com/BinaryBourbon/fountain/issues/649)).
- **Closing the client does not stop anything.** The conversation is on the
  server; the process is a window onto it. Reopen with `session/load`, or from
  the conversations app, or `fountain conv`.

## When something goes wrong

Start with stderr (`--log-level debug` if the default is not enough). Errors
are worded for a reader inside an editor rather than a terminal:

| Message | Meaning |
|---|---|
| `no Fountain agent configured` | The entry has no `--agent`. |
| `agent "x" runs the gemini runtime, which does not speak ACP` | Use that agent from the conversations app or `fountain run`. |
| `credentials for … were rejected` | Run `fountain auth login`. The message names the instance it tried, which is usually the surprise. |
| `could not resolve agent "x" on …` | Wrong name, or the right name on a different instance. |
| `the sandbox never started: …` | Provisioning failed, and the reason is the sandbox provider's. |
| `could not reattach to the sandbox, prompt again to provision a fresh one` | The sandbox was reclaimed, and the transcript survives. |

Running the binary by hand is a fair diagnostic, since it sits waiting for JSON-RPC
on stdin, which proves the process starts and finds its credentials.

## Where it is used

| Client | Who spawns it | Page |
|---|---|---|
| Zed and other ACP editors | The editor, from its agent-server config | [Editors](editors.md) |
| OpenClaw (Telegram, Discord, Slack) | The `acpx` plugin on the OpenClaw host | [OpenClaw](openclaw.md) |
| Buzz (Nostr) | `buzz-acp`, supervised **by Fountain itself** on the gateway, one per hosted identity | [Buzz](buzz.md) |
