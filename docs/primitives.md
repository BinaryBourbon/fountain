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

- **`model`** - `provider/model-id` (e.g. `anthropic/claude-sonnet-4-6`)
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

1. POST to `/api/conversations` with `agent_id` (and optional `vault_id`, `prompt`, `images`)
2. Fountain resolves the full env-var set and spawns a Sprites sandbox
3. The agent runs; log events stream in real time over SSE (`GET /api/conversations/:id/stream`)
4. Follow-up prompts go to `POST /api/conversations/:id/prompts`; a running turn can be interrupted (`POST .../interrupt`) and the whole conversation ended early (`POST .../terminate`)
5. The sandbox exits when the conversation terminates, or when it is reclaimed for being idle (default 60 minutes with no turn activity) or for reaching its maximum lifetime (default 24 hours)

Reclaiming ends the **sandbox**, not the conversation. The conversation stays resumable: the next prompt provisions a fresh sandbox and the runtime resumes the same session, so history is preserved and the only cost is the provisioning wait. Self-hosters can widen or disable both bounds with `SANDBOX_IDLE_TIMEOUT_MINUTES` and `SANDBOX_MAX_LIFETIME_HOURS` (`0` disables).

### Status lifecycle

```
pending -> running -> idle -> running   (idle between turns; a follow-up prompt resumes it)
                    -> failed
```

Any non-terminal state can move to `terminated` via `POST /api/conversations/:id/terminate`.

---

## Substitution

All string values in Agent configs support `${VAR}` interpolation:

| Syntax | Result |
|---|---|
| `${VAR}` | Value of `VAR` from the merged env map |
| `$$` | Literal `$` |

Substitution is recursive (works inside maps and lists) and fail-complete - all missing variables are reported at once.
