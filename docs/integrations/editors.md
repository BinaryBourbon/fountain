# Editors (Agent Client Protocol)

Fountain speaks the [Agent Client Protocol](https://agentclientprotocol.com)
(ACP), so an ACP-capable editor can drive a conversation running on a Fountain
agent: prompt it, watch it think and call tools, cancel it, close the editor,
and reopen the conversation later.

The editor spawns `fountain acp` as a subprocess and talks JSON-RPC to it over
the pipe. That process talks HTTP and SSE to your Fountain instance.

```
  editor  ──spawns──▶  fountain acp  ──HTTPS──▶  Fountain  ──ACP──▶  sandbox
   (ACP over stdio)                                                  (the agent)
```

## What this is, and is not

It is a **control surface for a remote conversation**. The agent runs in a
Fountain sandbox, on a checkout the sandbox made, on a machine that is not
yours.

It is **not** a way for the agent to edit the files open in your editor. The
integration declares no filesystem or terminal access, and the file paths a
tool call reports are paths inside the sandbox — they are deliberately not sent
as clickable locations, because clicking one would open the wrong file on your
machine or nothing at all. They travel under
`_meta.fountain.sandboxLocations` instead.

Why reach for this rather than a local agent, then:

- **The work outlives the editor.** Close the laptop mid-turn; the turn keeps
  running. Reopen and the transcript is replayed from the server.
- **The unit is a Fountain agent** — an environment, vault overrides, skills,
  MCP servers and inference credentials that never touch your machine.
- **The same conversation is open in the conversations app**, for you or a teammate,
  while it runs.

## Setup

1. Install the CLI and log in:

    ```bash
    brew install BinaryBourbon/tap/fountain
    fountain auth login
    ```

    For a self-hosted instance, point at it first — the CLI defaults to the
    hosted one:

    ```bash
    FOUNTAIN_BASE_URL=https://fountain.example.com fountain auth login
    ```

2. Pick an agent. `fountain agent list` shows yours; the editor entry names one
   agent, so add one entry per agent you want to reach.

3. Configure your editor (below), and start a new thread with it.

### Zed

In `settings.json` (`zed: open settings`):

```json
{
  "agent_servers": {
    "Fountain: researcher": {
      "type": "custom",
      "command": "fountain",
      "args": ["acp", "--agent", "researcher"],
      "env": {}
    }
  }
}
```

Use the agent's name or id in `--args`. To reach a non-default instance or
profile, add `"--profile", "staging"` to `args`, or set `FOUNTAIN_BASE_URL` in
`env`.

### Per-entry secrets

`--vault <name-or-id>` attaches a [vault](../primitives.md#vault) to every
conversation the entry opens. Vault values override the agent's environment, so
this is where a secret that belongs to *this entry* goes — an identity the
agent posts under, a token scoped to one workspace.

```json
"args": ["acp", "--agent", "researcher", "--vault", "researcher-identity"]
```

The distinction matters as soon as there are two entries. An environment is
shared by every agent attached to it, so a credential put there is used by all
of them; a vault is attached per conversation, so two entries stay separate
even when they point at the same agent.

### Per-entry environments

`--environment <name-or-id>` provisions every conversation the entry opens from
that [environment](../primitives.md#environment) instead of the agent's own.
Use it when one agent config should run under several baselines — the same
"engineer" against a `fountain` environment in one entry and a `buzz`
environment in another — without duplicating the agent. The vault, if any,
still wins over it on key collision, and an agent can restrict which
environments may stand in for its own via `allowed_environment_ids`.

### Any other ACP client

There is nothing Zed-specific in the adapter. Whatever your client calls it,
the agent command is:

```bash
fountain acp --agent <name-or-id>
```

spoken to over stdin/stdout. [Buzz](https://github.com/block/buzz) is
ACP-native and should work the same way, though its configuration format for a
custom agent is not something we have verified — if you get it working, a note
in an issue would be welcome.

## What you get

The adapter's full protocol surface — every method, the `_meta` extensions
chat harnesses use, what is forwarded and what is deliberately ignored — is on
the [`fountain acp` reference](acp.md). The short version:


| ACP | What happens |
|---|---|
| `initialize` | Capability handshake. Protocol version 1 |
| `authenticate` | Uses the credentials `fountain auth login` saved. No second login |
| `session/new` | Creates a conversation for the configured agent |
| `session/prompt` | Runs a turn; messages, thoughts and tool calls stream back as they happen |
| `session/cancel` | Interrupts the running turn |
| `session/load` | Replays the conversation into a freshly opened editor |

Images in a prompt are supported. A dropped connection is not a lost turn: the
server closes an idle stream after 60 seconds and the adapter reconnects and
resumes from where it left off.

## Limits, stated rather than discovered

- **No access to your local files**, as above.
- **Agents on the `gemini` runtime are refused** when the editor opens a
  session, by name. Gemini is not on ACP yet
  ([#659](https://github.com/BinaryBourbon/fountain/issues/659)); use those
  agents from the conversations app or `fountain run`.
- **Permission prompts are not forwarded yet.** Agents currently run with their
  own permission handling, so an editor will not be asked to approve a tool
  call ([#643](https://github.com/BinaryBourbon/fountain/issues/643),
  [#708](https://github.com/BinaryBourbon/fountain/issues/708)).
- **A reclaimed sandbox loses the agent's memory.** If a conversation's sandbox
  was reclaimed while you were away, `session/load` still replays the full
  transcript, but the agent itself does not remember it
  ([#649](https://github.com/BinaryBourbon/fountain/issues/649)).

## When something goes wrong

`fountain acp` writes the protocol to stdout and **everything else to stderr**,
which is where your editor's agent-server log will show it. Start there.

```bash
# what the editor runs, with more detail
fountain acp --agent researcher --log-level debug
```

Errors are written to be readable inside an editor rather than in a terminal:

| Message | Meaning |
|---|---|
| `no Fountain agent configured` | The entry has no `--agent` |
| `agent "x" runs the gemini runtime, which does not speak ACP` | See the limits above |
| `credentials for … were rejected` | Run `fountain auth login`. The message names the instance it tried, which is usually the surprise |
| `could not resolve agent "x" on …` | Wrong name, or the right name on a different instance |

Running the binary by hand is a fair diagnostic — it will sit waiting for
JSON-RPC on stdin, which tells you the process starts and finds its
credentials.

## How it works

Two ADRs cover the design:
[0014](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0014-agent-client-protocol.md)
made Fountain an ACP *client* of the coding agents it runs in sandboxes;
[0015](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0015-fountain-as-an-acp-agent.md)
makes it an ACP *agent* for editors. Together they make Fountain a proxy: the
same block vocabulary arrives from a sandbox on one side and leaves for an
editor on the other, so the adapter forwards updates rather than translating
them, and no runtime's output format is parsed twice.
