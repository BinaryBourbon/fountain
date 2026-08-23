# Runtimes

A runtime is the coding-agent CLI that a sandbox runs. It is one field on an
[Agent](../../concepts/agent.md). It decides which provider's credential that
agent needs, how skills land on disk, and where Fountain writes the system
prompt.

## All four

| Runtime | Provider | Transport | Multi-provider |
|---|---|---|---|
| [claude](claude.md) | `anthropic` | ACP | No |
| [codex](codex.md) | `openai` | ACP | No |
| [opencode](opencode.md) | Any of the three | ACP | **Yes** |
| [gemini](gemini.md) | `google` | ACP, through `gemini --acp` | No |

## How to choose

**Choose the runtime whose provider you hold a key for.** That constraint
decides it most of the time. Inference credentials belong to one user, who
enters them in the app, and Fountain can export keys for exactly three
providers. Read
[Services Fountain uses](../../integrations/index.md).

**Choose `opencode` to make one agent definition work across providers.** It
is the only multi-provider runtime. It takes the canonical `provider/model-id`
string word for word, then reads the prefix to decide which key to export.

**All four speak ACP.** Gemini was the last one off it, and it joined on
2026-08-22. So editor integration, the permission flow and the shared block
format reach every runtime, and the choice is about the provider and the CLI
rather than about the transport.

## The rule that catches people

Fountain stores `model` as `provider/model-id`. **It validates the provider
half, and it does not validate the model id.**

The provider must match the runtime. Fountain rejects a mismatch when you save
the agent. It holds no credential for the wrong provider, and the sandbox
would start with no inference key at all.

Fountain passes the model id to the CLI unchanged. A model that ships after
your Fountain version still works, and a typo reaches the CLI and fails there.

## Suggested models

The agent form offers these as suggestions. They are not an allowlist.

| Provider | Suggested |
|---|---|
| `anthropic` | `claude-opus-5`, `claude-sonnet-5`, `claude-opus-4-8`, `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5` |
| `openai` | `gpt-5.3-codex`, `gpt-5.5` |
| `google` | `gemini-3.1-pro-preview`, `gemini-3.7-flash` |

`GET /api/catalog` returns this list for each runtime. A client can then
render the current set, and it does not hard-code one.

## Where skills and prompts land

Each runtime has its own layout on disk. That is why one skill list produces
different paths.

| Runtime | Skills root | skills.sh agent | System prompt |
|---|---|---|---|
| `claude` | `/home/sprite/.claude/skills` | `claude-code` | `~/.claude/CLAUDE.md` |
| `codex` | `/home/sprite/.codex/skills` | `codex` | `~/.codex/AGENTS.md` |
| `opencode` | `/tmp/.config/opencode/skills` | `opencode` | `~/.config/opencode/AGENTS.md` |
| `gemini` | `/tmp/.gemini/skills` | `gemini-cli` | `~/.gemini/GEMINI.md` |

## Related

- [About agents](../../concepts/agent.md), where you set `runtime`.
- [Skills](../skills/index.md).
- [`fountain acp`](../../integrations/acp.md), the adapter that three of the
  four speak through.
