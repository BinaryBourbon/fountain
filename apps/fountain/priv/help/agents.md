# Agents

An **Agent** is a named configuration for a single coding-agent CLI. It bundles together:

- a **runtime** (`claude` / `codex` / `gemini` / `opencode`) — which binary runs in the sprite
- a **model** (`anthropic/claude-sonnet-4-6`, `openai/gpt-5.1`, `google/gemini-2.5-pro`, etc.)
- an optional **system prompt** (`system`)
- an optional **environment** reference (`environment_id` or `environment` by name) — the sprite shape to provision
- optional **skills** — names of bundled skills to mount into the sprite
- optional **mcp_servers** — MCP servers the agent should connect to

When you start a conversation against an agent, Fountain provisions a fresh sprite based on the environment, mounts the agent's skills, writes runtime-specific config (e.g. claude's `~/.claude.json`), and runs the runtime CLI inside.

## Create one via the API

```bash
curl -s -X POST "$FOUNTAIN_BASE_URL/api/agents" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" -H "Content-Type: application/json" \
  -d '{
    "name": "researcher",
    "runtime": "claude",
    "model": "anthropic/claude-sonnet-4-6",
    "system": "You are a research assistant. Cite primary sources.",
    "skills": ["aod"],
    "mcp_servers": {
      "everything": {
        "command": "npx",
        "args": ["-y", "@modelcontextprotocol/server-everything"]
      }
    }
  }'
```

The `model` field always uses the `provider/model` shape — even though codex/gemini don't pass it through to the CLI, the schema enforces the format.

## Updating

`PUT /api/agents/:id` with the same body shape updates it in place. The next conversation picks up the new config; running conversations are unaffected.

## Bulk-managing via manifest

If you've got more than two or three agents, use **`fountain apply -f fountain.yml`**. See **Manifest** for the YAML format.

## `${VAR}` substitution in `mcp_servers`

Most MCP clients don't expand env vars in their config — they read literal strings. So when Fountain writes the runtime's MCP config (claude's `~/.claude.json`, codex's `~/.codex/config.toml`, etc.), it substitutes `${VAR}` references **eagerly**, at provision time, against the merged `env_vars` + environment secrets + vault secrets map. Vault wins on key collision.

```yaml
mcp_servers:
  github:
    type: http
    url: https://api.githubcopilot.com/mcp/
    headers:
      Authorization: "Bearer ${GITHUB_TOKEN}"   # ← resolved from env or vault
```

Rules:

| Syntax     | Meaning                                              |
| ---------- | ---------------------------------------------------- |
| `${VAR}`   | eager — substituted at provision time                |
| `$${VAR}`  | escape — written through as the literal `${VAR}`     |
| `$$`       | literal `$`                                          |

Identifiers must be `[A-Z_][A-Z0-9_]*` (UPPER_SNAKE_CASE), the same shape as secret keys. Substitution recurses into nested maps and lists, so `headers`, `args`, and `env` all work the same way.

If the agent references a key that's missing from both the environment and the conversation's vault, **provisioning fails** — the conversation is marked `failed` and the missing names show up in the `provision/failed` stage event. This is deliberate: half-substituted configs are confusing to debug.

Use `$${VAR}` only when the MCP server (or some downstream process the runtime spawns) is going to expand the reference itself. That's rare today.

## Available runtimes

| runtime | CLI | model format | auth |
| --- | --- | --- | --- |
| claude | `claude` | `anthropic/claude-sonnet-4-6` | `CLAUDE_CODE_OAUTH_TOKEN` (preferred) or `ANTHROPIC_API_KEY` |
| codex | `codex` | `openai/gpt-5.1` | `OPENAI_API_KEY` (consumed via `codex login --with-api-key` at provision time) |
| gemini | `gemini` | `google/gemini-2.5-pro` | `GEMINI_API_KEY` |
| opencode | `opencode` | `provider/model` (anthropic / openai / google) | per provider |

Each has its own quirks — codex needs a one-shot login, opencode auto-installs from `bun install -g`, gemini needs `--allowed-mcp-server-names` for MCP, etc. The runtime modules in `apps/fountain/lib/fountain/runtimes/*.ex` handle these transparently.

## Skills

Skills are reusable instructional/context files that get mounted into a sprite at provision time so the runtime can find them.

- For **claude** and **opencode**: dropped under `~/.claude/skills/<name>/SKILL.md`.
- For **codex**: concatenated into `~/.codex/AGENTS.md`.
- For **gemini**: concatenated into `~/.gemini/GEMINI.md`.

Bundled skills live under `apps/fountain/priv/sprite_skills/`. Reference them by directory name in the agent's `skills` array. The bundled `aod` skill is **always** mounted regardless — it's how a sprite-internal agent calls back to spawn more conversations.
