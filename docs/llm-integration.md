# LLM integration

Fountain is built to be consumed by AI coding tools. Every instance exposes machine-readable discovery endpoints so any agentic IDE can learn the full API from a single fetch.

The examples below run against your own instance — point `FOUNTAIN_URL` at it:

```bash
FOUNTAIN_URL=http://localhost:4000
```

## Drop-in skill for Claude Code

```bash
mkdir -p ~/.claude/skills/fountain
curl -fsSL $FOUNTAIN_URL/skill > ~/.claude/skills/fountain/SKILL.md
```

After that, telling Claude "spin up a researcher agent on Fountain and have it audit the auth module" Just Works.

## Discovery endpoints

| Endpoint | Content | Best for |
|---|---|---|
| `/llms.txt` | Concise API summary (~500 tokens) | Context-constrained models |
| `/llms-full.txt` | Full API reference | Deep tool-calling agents |
| `/skill` | Claude Code / Cursor skill file | IDE skills |

```bash
curl $FOUNTAIN_URL/llms.txt
curl $FOUNTAIN_URL/llms-full.txt
```

## MCP server (coming soon)

Fountain will ship a first-party MCP server exposing all four primitives as tools:

```json
{
  "mcpServers": {
    "fountain": {
      "command": "npx",
      "args": ["-y", "@fountain/mcp-server"],
      "env": {
        "FOUNTAIN_API_KEY": "ftn_your_api_key",
        "FOUNTAIN_BASE_URL": "https://your-fountain.example.com"
      }
    }
  }
}
```

## Using the API from an agent

1. Load the skill from `/skill` at session start
2. Authenticate with a Fountain API key stored in the agent's environment
3. Use the CLI or REST API to spin up sub-agents

Example prompt:

```
Please:
1. Create a Fountain conversation using the "security-auditor" agent
2. Set the prompt to: "Audit apps/fountain/lib/fountain_web/controllers/ for OWASP Top 10 issues"
3. Stream the output and report findings
```
