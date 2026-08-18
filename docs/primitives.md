# The four primitives

Everything in Fountain is built from four concepts.

---

## Environment

An **Environment** is a named, reusable baseline for a coding agent:

- **Encrypted secrets** - key/value env vars, encrypted per-tenant with AES-256-GCM. Write-only: once stored, the API never returns a value (listing returns keys and timestamps only).
- **Plain env vars** - a non-secret `env_vars` map for values that aren't sensitive (feature flags, endpoints). Returned by the API as-is; put anything sensitive in secrets instead.
- **Runtime config** - packages to install, repos to clone, a setup script
- **Networking policy** - `networking_type: unrestricted` or `limited`. Sprites are open by default, so `unrestricted` is a no-op. `limited` restricts egress to the domains in `networking_config.allowed_hosts` (the only `networking_config` key honored today); under `limited` with no `allowed_hosts`, nothing is allowlisted.

Environments attach to Agents at creation time. Many agents can share one environment.

```yaml
apiVersion: fountain.dev/v1
kind: Environment
metadata:
  name: python-data-env
spec:
  packages:
    python: "3.12"
  networking_type: limited
  secrets:
    - key: OPENAI_API_KEY
      value: sk-...   # encrypted at rest, never returned by the API
```

---

## Vault

A **Vault** is a free-floating bag of env-var overrides.

**Key rule: vault values win on key collision.** When Fountain materializes env vars for a conversation, it merges `environment secrets -> vault secrets`. The vault always takes precedence.

Typical uses: per-customer API keys, staging vs. production credentials, temporary overrides.

```yaml
apiVersion: fountain.dev/v1
kind: Vault
metadata:
  name: staging-creds
spec:
  secrets:
    - key: DATABASE_URL
      value: postgres://staging-host/mydb
```

---

## Agent

An **Agent** is a named, re-runnable configuration for an AI coding assistant:

- **`model`** - `provider/model-id` (e.g. `anthropic/claude-sonnet-4-6`), passed
  to the runtime's CLI. The provider must match the runtime: `anthropic` for
  `claude`, `openai` for `codex`, `google` for `gemini`. `opencode` is
  multi-provider and takes any of the three — it uses the prefix to pick which
  API key to export. A provider outside that set is rejected at write time:
  there is no credential for it, so the sandbox would have started with no
  inference key at all. The model id itself is *not* checked against a list —
  the agent form suggests current models, but anything you type is passed to
  the CLI as-is, so a model released since your Fountain version still works.
- **`runtime`** - one of `claude`, `codex`, `gemini`, `opencode`
- **`environment`** - optional Environment to attach
- **`system`** / **`description`** - system prompt and human-readable description
- **`skills`** - each entry is either inline (`{name, content}` — a full SKILL.md written to the sandbox) or GitHub-sourced (`{source: "owner/repo"}` — installed via the skills.sh CLI)
- **`mcp_servers`** - MCP server definitions, with `${VAR}` substitution in their env
- **`metadata`** - free-form map for callers' own bookkeeping

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

`${GITHUB_PAT}` is a substitution reference resolved from the merged env + vault secrets at spawn time.

---

## Conversation

A **Conversation** is a running session of an Agent inside a sandboxed VM. It starts with one prompt and can continue over multiple turns:

1. POST to `/api/conversations` with `agent_id` (and optional `vault_id`, `environment_id` — an environment to provision from instead of the agent's own — `prompt`, `images`)
2. Fountain resolves the full env-var set and spawns a Sprites sandbox
3. The agent runs; log events stream in real time over SSE (`GET /api/conversations/:id/stream`)
4. Follow-up prompts go to `POST /api/conversations/:id/prompts`; a running turn can be interrupted (`POST .../interrupt`) and the whole conversation ended early (`POST .../terminate`)
5. After 60 minutes with no turn activity (default) the sandbox is **suspended**: it scales to zero, costs nothing while parked, and the next prompt wakes it with the agent's memory intact. At 24 hours of continuous running (default) it is **destroyed** — the ceiling for a conversation that never stops being busy.

Neither bound ends the conversation — it stays resumable either way. Self-hosters can widen or disable both bounds with `SANDBOX_IDLE_TIMEOUT_MINUTES` and `SANDBOX_MAX_LIFETIME_HOURS` (`0` disables).

!!! note "Suspend keeps the agent's memory; the max-lifetime ceiling does not"

    The runtime keeps its session on the sandbox's disk. A suspended sandbox
    keeps that disk, so waking it resumes the agent right where it left off.
    A sandbox that hits the max-lifetime ceiling is destroyed, disk and all:
    the stored transcript survives and the conversation stays resumable, but
    the next turn starts a fresh session and the agent answers without the
    earlier ones. Expect to restate context after a ceiling reclaim.

### Status lifecycle

```
pending -> running -> idle -> running   (idle between turns; a follow-up prompt resumes it)
                    -> failed
```

Any non-terminal state can move to `terminated` via `POST /api/conversations/:id/terminate`.

### The team page: agents as teammates

`/team` in the web UI lays conversations out like a messaging app — the
roster on the left, one thread on the right — and treats each agent as a
teammate with **one** ongoing conversation. There is no fifth primitive
behind it: a teammate *is* a Conversation, bound to the reserved channel
`fountain:team` the same way a Buzz channel binds one through `channel_id`.
Adding an agent to the team opens that conversation, which provisions the
agent its own sandbox — its computer. A message is a follow-up turn on it; a
suspended or reaped sandbox wakes on the next message as usual, and a
terminated conversation is replaced by a fresh one under the same binding,
so the teammate stays reachable. Removing a teammate terminates the live
conversation and unbinds the agent's conversations from the channel; the
rows stay in the ordinary conversation list. "Details" on a thread opens the
full conversation view (stages, tool calls, raw output).

When you add a teammate you can give it a name of its own, pick the
environment its computer is set up from, and attach a vault. These are the
conversation's `title`, its per-launch environment override and its
`vault_id` — nothing new — and the environment and vault pickers only offer
what the agent's `allowed_environment_ids` / `allowed_vault_ids` allow. They
belong to the teammate, not the computer: a fresh conversation opened after
the old one is terminated inherits all three.

---

## Substitution

All string values in Agent configs support `${VAR}` interpolation:

| Syntax | Result |
|---|---|
| `${VAR}` | Value of `VAR` from the merged env map |
| `$$` | Literal `$` |

Substitution is recursive (works inside maps and lists) and fail-complete - all missing variables are reported at once.
