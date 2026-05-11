# The four primitives

Everything in Fountain is built from four concepts.

---

## Environment

An **Environment** is a named, reusable baseline for a coding agent:

- **Encrypted secrets** - key/value env vars, encrypted per-tenant with AES-256-GCM
- **Runtime config** - packages to install, repos to clone, a setup script
- **Networking policy** - `unrestricted`, `egress_only`, or `isolated`

Environments attach to Agents at creation time. Many agents can share one environment.

```yaml
apiVersion: fountain.dev/v1
kind: Environment
metadata:
  name: python-data-env
spec:
  packages:
    python: "3.12"
  secrets:
    - key: OPENAI_API_KEY
      value: sk-...   # encrypted at rest
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

An **Agent** is a named, re-runnable configuration for an AI coding assistant.

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
    - fountain-api
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

A **Conversation** is a single run of an Agent inside a sandboxed VM.

1. POST to `/api/v1/conversations` with `agent_id` (and optional `vault_id` and `prompt`)
2. Fountain resolves the full env-var set and spawns a Sprites sandbox
3. The agent runs; log events stream in real time over SSE
4. The sandbox exits when the agent finishes or a timeout hits

### Status lifecycle

```
pending -> running -> completed
                  -> failed
                  -> timed_out
```

---

## Substitution

All string values in Agent configs support `${VAR}` interpolation:

| Syntax | Result |
|---|---|
| `${VAR}` | Value of `VAR` from the merged env map |
| `$$` | Literal `$` |

Substitution is recursive (works inside maps and lists) and fail-complete - all missing variables are reported at once.
