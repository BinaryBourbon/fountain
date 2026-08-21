# Runtimes

A runtime is the coding-agent CLI a sandbox runs. It is one field on an
[Agent](../../concepts/agent.md), and it decides which provider's credential
that agent needs, how skills land on disk, and where the system prompt is
written.

## All four

| Runtime | Provider | Transport | Multi-provider |
|---|---|---|---|
| [claude](claude.md) | `anthropic` | ACP | No |
| [codex](codex.md) | `openai` | ACP | No |
| [opencode](opencode.md) | any of the three | ACP | **Yes** |
| [gemini](gemini.md) | `google` | legacy stream | No |

## How to choose

**Pick the runtime whose provider you have a key for.** This is the constraint
that decides it most of the time. Inference credentials are per-user, entered
in the running app, and Fountain can export keys for exactly three providers.
See [Services Fountain uses](../../integrations/index.md).

**Pick `opencode` if you want one agent definition to work across providers.**
It is the only multi-provider runtime. It takes the canonical
`provider/model-id` string verbatim and reads the prefix to decide which key to
export.

**Avoid `gemini` unless you specifically want it.** It is the only runtime not
on ACP, so it does not get the editor integration, the permission plumbing or
the shared block format the other three share.

## The rule that catches people

`model` is stored as `provider/model-id`, and **the provider half is validated
while the model id is not.**

The provider must match the runtime. A mismatch is rejected when you save the
agent, because Fountain holds no credential for the wrong provider and the
sandbox would start with no inference key at all.

The model id is passed to the CLI unchanged. A model released after your
Fountain version still works, and a typo reaches the CLI and fails there.

## Suggested models

These are suggestions the agent form offers, not an allowlist.

| Provider | Suggested |
|---|---|
| `anthropic` | `claude-opus-5`, `claude-sonnet-5`, `claude-opus-4-8`, `claude-sonnet-4-6`, `claude-haiku-4-5` |
| `openai` | `gpt-5-codex`, `gpt-5` |
| `google` | `gemini-2.5-pro`, `gemini-2.5-flash` |

`GET /api/catalog` returns this list per runtime, so a client can render the
current set rather than hard-coding one.

## Where skills and prompts land

Each runtime has its own on-disk layout, which is why the same skill list
produces different paths.

| Runtime | Skills root | skills.sh agent | System prompt |
|---|---|---|---|
| `claude` | `/home/sprite/.claude/skills` | `claude-code` | `~/.claude/CLAUDE.md` |
| `codex` | `/home/sprite/.codex/skills` | `codex` | `~/.codex/AGENTS.md` |
| `opencode` | `/tmp/.config/opencode/skills` | `opencode` | `~/.config/opencode/AGENTS.md` |
| `gemini` | `/tmp/.gemini/skills` | `gemini-cli` | `~/.gemini/GEMINI.md` |

## Related

- [About agents](../../concepts/agent.md), where `runtime` is set.
- [Skills](../skills/index.md).
- [`fountain acp`](../../integrations/acp.md), the adapter three of the four
  speak through.
