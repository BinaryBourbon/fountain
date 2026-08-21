# About agents

This page explains what an Agent is and which of its fields carry decisions
rather than settings. For every field, see the
[API reference](../api.md).

## What an agent is

An Agent is a named, re-runnable configuration for a coding agent. It is
config, not a process. Nothing runs until a [Conversation](conversation.md)
runs it.

An Agent decides seven things.

- **`model`**, as `provider/model-id`, for example
  `anthropic/claude-sonnet-4-6`.
- **`runtime`**, one of `claude`, `codex`, `gemini` or `opencode`.
- **`environment`**, an optional [Environment](environment.md) to provision
  from.
- **`system`** and **`description`**, the system prompt and a human-readable
  summary.
- **`skills`**, either inline or sourced from GitHub.
- **`mcp_servers`**, MCP server definitions with `${VAR}` substitution in their
  env.
- **`metadata`**, a free-form map for your own bookkeeping.

## Why it exists

An Agent is the thing you name and hand to someone else.

Without it, every run would carry its own model choice, prompt and tool
configuration, and two people asking the same agent for the same thing would
get different behavior. The Agent is the unit that makes a run repeatable and
the unit a teammate is built from. See
[agents as teammates](teammates.md).

## Why the provider is checked and the model id is not

This trips people up, and the asymmetry is deliberate.

The provider must match the runtime. `anthropic` for `claude`, `openai` for
`codex`, `google` for `gemini`. `opencode` is multi-provider and takes any of
the three, using the prefix to pick which API key to export.

A provider outside that set is rejected at write time. Fountain holds no
credential for it, so a sandbox provisioned that way would start with no
inference key at all and fail on the first turn with an error that pointed
nowhere useful. Rejecting at write time turns a confusing runtime failure into
a clear form error.

The model id itself is not checked against a list. The agent form suggests
current models, and whatever you type is passed to the runtime's CLI unchanged.
A model released after your Fountain version still works. Validating the id
would mean shipping a list that goes stale between releases, and the cost of a
stale allowlist is worse than the cost of a typo.

## How the system prompt reaches the machine

The system prompt is written into the runtime's user-level instructions file on
the agent's sandbox, at provision and again at every reattach.

| Runtime | File |
|---|---|
| `claude` | `~/.claude/CLAUDE.md` |
| `codex` | `~/.codex/AGENTS.md` |
| `opencode` | `~/.config/opencode/AGENTS.md` |
| `gemini` | `~/.gemini/GEMINI.md` |

Because it is rewritten on reattach, editing an Agent's system prompt reaches
an existing sandbox the next time that sandbox wakes. It does not reach a turn
that is already in flight.

## Skills and MCP servers

Each `skills` entry is either inline or GitHub-sourced. An inline entry is
`{name, content}` and writes a full `SKILL.md` into the sandbox. A GitHub entry
is `{source: "owner/repo"}` and is installed with the skills.sh CLI.

Two skills are bundled into every sandbox regardless of what an Agent asks
for.

- **`fountain`** gives the agent Fountain's own API, so it can spawn
  sub-conversations.
- **`create-team`** is a question-and-answer flow that sets up the user's team.
  A first teammate runs it when someone answers `/create-team`.

`mcp_servers` entries support `${VAR}` substitution in their `env`, resolved
from the merged environment and vault secrets at spawn time.

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: researcher
spec:
  model: anthropic/claude-sonnet-4-6
  runtime: claude
  environment: python-data-env
  skills:
    - source: BinaryBourbon/fountain-api-skill
  mcp_servers:
    github:
      command: npx
      args: ["-y", "@modelcontextprotocol/server-github"]
      env:
        GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

`${GITHUB_PAT}` resolves from the merged environment and vault secrets. See
[substitution](../api.md).

## What an agent is not

**Not a running process.** An Agent that has never been run has no sandbox, no
memory and no cost.

**Not a hard scope.** `allowed_environment_ids` and `allowed_vault_ids` bound
which Environments and Vaults a launch may name. They are the Agent's own
allowlists rather than a tenancy boundary. Tenancy is enforced separately, on
every query.

**Not the ACP sense of "agent".** In the Agent Client Protocol, "agent" means
the process an editor spawns. See
[`fountain acp`](../integrations/acp.md).

## Where to go next

- [About conversations](conversation.md), which run an Agent.
- [Agents as teammates](teammates.md), which is one Conversation per Agent.
- [About environments](environment.md), which an Agent names.
- [Glossary](../reference/glossary.md), for the three senses of "agent".
