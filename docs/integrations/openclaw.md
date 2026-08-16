# OpenClaw (Agent Client Protocol)

[OpenClaw](https://docs.openclaw.ai) is a self-hosted personal assistant that
fronts a set of chat surfaces — Telegram, Discord, Slack, Signal, iMessage and
more — and routes them to coding harnesses over the
[Agent Client Protocol](https://agentclientprotocol.com) (ACP). Because
Fountain already speaks ACP as an *agent* (`fountain acp`, see
[Editors](editors.md)), OpenClaw can drive a Fountain agent the same way it
drives Claude Code or Codex: you talk to it from a chat channel, and the turn
runs in a Fountain sandbox.

There is nothing new to build. OpenClaw is an ACP *client*; `fountain acp` is
an ACP *agent*; its `acpx` plugin can point at any custom command that speaks
ACP over stdio. So the integration is a config block, not code.

```
  OpenClaw (acpx)  ──spawns──▶  fountain acp  ──HTTPS──▶  Fountain  ──ACP──▶  sandbox
   (a chat channel)   (ACP over stdio)                                        (the agent)
```

## What this is, and is not

It is a **chat front-end for a remote conversation.** OpenClaw handles the
channel (a Telegram thread, a Discord room); Fountain runs the agent in a
sandbox, on a checkout the sandbox made, on a machine that is not the one
OpenClaw runs on. The reply streams back to the channel over ACP — OpenClaw
delivers the agent's message chunks to the chat as they arrive, so no publish
tool or extra wiring is involved.

It is **not** a way for the agent to touch OpenClaw's host or the files on it.
The adapter declares no filesystem or terminal access, and the paths a tool
call reports are paths *inside the sandbox* — carried under
`_meta.fountain.sandboxLocations` rather than as clickable locations. For a
chat surface this is a clean fit rather than a caveat: there is no local
project to confuse them with.

Why reach for this rather than a harness OpenClaw hosts locally:

- **The work outlives the channel.** Close the chat mid-turn; the turn keeps
  running. Re-open and the transcript replays from the server.
- **The unit is a Fountain agent** — an environment, vault overrides, skills,
  MCP servers and inference credentials that never touch the OpenClaw host.
- **The same conversation is open in the Fountain web UI**, for you or a
  teammate, while it runs from the channel.

## Setup

OpenClaw runs on Node — it requires **Node ≥ 22.22.3** (or ≥ 24.15 / ≥ 25.9).

1. Install the Fountain CLI on the OpenClaw host and log in:

    ```bash
    brew install BinaryBourbon/tap/fountain
    fountain auth login
    ```

    For a self-hosted instance, point at it first — the CLI defaults to the
    hosted one:

    ```bash
    FOUNTAIN_BASE_URL=https://fountain.example.com fountain auth login
    ```

    OpenClaw spawns `fountain acp` as a child process and it inherits that
    environment, so the credentials `fountain auth login` saved are what the
    session authenticates with. No key goes into OpenClaw's config.

2. Install and enable the ACP backend plugin:

    ```bash
    openclaw plugins install @openclaw/acpx
    openclaw config set plugins.entries.acpx.enabled true
    ```

3. Register Fountain as a custom ACP agent. Pick an agent
   (`fountain agent list` shows yours); one entry names one agent, so add one
   entry per agent you want to reach.

    ```json5
    plugins: {
      entries: {
        acpx: {
          enabled: true,
          config: {
            agents: {
              // the id you spawn/bind, mapped to the command OpenClaw runs
              fountain: { command: "fountain", args: ["acp", "--agent", "researcher"] }
            },
            // until permission forwarding lands (see Limits), the sandbox's own
            // policy runs the turn; ask acpx not to block on an approval prompt
            permissionMode: "approve-all"
          }
        }
      }
    }
    ```

4. Spawn it from a channel, or bind a channel to it:

    ```
    /acp spawn fountain
    ```

    ```json5
    // pin a Discord channel to this agent
    bindings: [
      { type: "acp", agentId: "fountain",
        match: { channel: "discord", peer: { kind: "channel", id: "…" } } }
    ]
    ```

### Per-entry secrets

`--vault <name-or-id>` attaches a [vault](../primitives.md#vault) to every
conversation the entry opens. Vault values override the agent's environment, so
this is where a secret that belongs to *this entry* goes — an identity the
agent posts under, a token scoped to one channel.

```json5
fountain: { command: "fountain", args: ["acp", "--agent", "researcher", "--vault", "researcher-identity"] }
```

The distinction matters as soon as there are two entries. An environment is
shared by every agent attached to it; a vault is attached per conversation, so
two entries stay separate even when they point at the same agent.

## What you get

| ACP | What happens |
|---|---|
| `initialize` | Capability handshake. Protocol version 1 |
| `authenticate` | Uses the credentials `fountain auth login` saved on the host. Skipped when already logged in |
| `session/new` | Creates a conversation for the configured agent |
| `session/prompt` | Runs a turn; messages, thoughts and tool calls stream back to the channel as they happen |
| `session/cancel` | `/acp cancel` interrupts the running turn |
| `session/load` | Replays the conversation when a session is resumed |
| `session/set_config_option` | Accepted, not applied. OpenClaw pushes the model its brain chose (and a `thinking` level derived from it) at every spawn; a Fountain agent's model is set on the agent, so the push is acknowledged and ignored, and the reply's `_meta.fountain.applied: false` says so |

## Limits, stated rather than discovered

- **No access to the OpenClaw host's files**, as above.
- **One identity per host.** OpenClaw is single-user and self-hosted, so every
  session authenticates as the host's Fountain login. Per-channel-user Fountain
  identities are not something this integration provides.
- **Agents on the `gemini` runtime are refused** when a session opens, by name.
  Gemini is not on ACP yet
  ([#659](https://github.com/BinaryBourbon/fountain/issues/659)); use those
  agents from the web UI or `fountain run`.
- **Permission prompts are not forwarded yet.** Agents currently run with their
  own permission handling, which is why `permissionMode: "approve-all"` is set
  above — an OpenClaw channel is not asked to approve a tool call
  ([#643](https://github.com/BinaryBourbon/fountain/issues/643),
  [#708](https://github.com/BinaryBourbon/fountain/issues/708)).
- **A gateway spawn opens two conversations, and uses one.** OpenClaw's
  `sessions_spawn(runtime: "acp", mode: "run")` asks acpx to ensure the session
  twice — once when the spawn is initialised, once when the turn runs — and in
  one-shot mode acpx answers each with a fresh `session/new`. On Fountain that
  is two conversations per spawn, each with a provisioned sandbox; the first is
  never prompted and sits `pending` until the idle reaper parks it. This is
  OpenClaw/acpx behaviour, not something the adapter can prevent
  ([#760](https://github.com/BinaryBourbon/fountain/issues/760)). Sessions
  bound to a channel thread (`mode: "session"`) reuse their record and do not
  pay this.
- **A reclaimed sandbox loses the agent's memory.** If a conversation's sandbox
  was reclaimed while you were away, resuming still replays the full transcript,
  but the agent itself does not remember it
  ([#649](https://github.com/BinaryBourbon/fountain/issues/649)).

## Verification

The ACP path here is the same one the [Editors](editors.md) integration uses,
proven end to end against production: an acpx-identical spawn —
`fountain acp --agent <id>` with the host environment inherited, line-delimited
JSON-RPC 2.0 over stdio — completed `initialize → session/new →
session/prompt`, ran the turn in a real sandbox, and streamed the agent's reply
back as `agent_message_chunk` updates with a real stop reason. That is exactly
what `acpx` does when it spawns the command above.

The full gateway round trip is also proven: `openclaw agent` (OpenClaw's own
brain) → `sessions_spawn(runtime: "acp", agentId: "fountain")` → acpx →
`fountain acp` → sandbox → the reply relayed back through the gateway, against
the real acpx (0.11.2) and OpenClaw (2026.7.1) — with the brain pushing its
model and a `thinking` level at the harness on the way, which is the case that
used to abort the turn ([#759](https://github.com/BinaryBourbon/fountain/issues/759),
[#760](https://github.com/BinaryBourbon/fountain/issues/760)).

If a session does not start, `fountain acp` writes the protocol to stdout and
**everything else to stderr**, which is where OpenClaw's `acpx` log shows it.
`/acp doctor` reports backend health; running the command by hand is a fair
diagnostic — it waits for JSON-RPC on stdin, which tells you the process starts
and finds its credentials:

```bash
fountain acp --agent researcher --log-level debug
```

| Message | Meaning |
|---|---|
| `no Fountain agent configured` | The entry has no `--agent` |
| `agent "x" runs the gemini runtime, which does not speak ACP` | See the limits above |
| `credentials for … were rejected` | Run `fountain auth login` on the host. The message names the instance it tried |
| `could not resolve agent "x" on …` | Wrong name, or the right name on a different instance |

## How it works

Two ADRs cover the design:
[0014](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0014-agent-client-protocol.md)
made Fountain an ACP *client* of the coding agents it runs in sandboxes;
[0015](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md)
makes it an ACP *agent* for any ACP client — an editor, [Buzz](https://github.com/block/buzz),
or OpenClaw. Together they make Fountain a proxy: the same block vocabulary
arrives from a sandbox on one side and leaves for the client on the other, so
the adapter forwards updates rather than translating them. OpenClaw is one more
client on that far side — see the
[2026-08-16 addendum to 0015](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md#addendum--2026-08-16-openclaw-is-another-acp-client-spike-verified).
