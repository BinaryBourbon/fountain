# Fountain

A multi-tenant API and UI for managing agents, repos, secrets, and conversations. It's for people who want to create sandboxed coding agent instances with preconfigured sets of env vars, MCP servers, skills, repos, and packages. Users treat Fountain as a building block for their own workflows, but also use the UI to get started and to debug. It exists because running Claude instances with worktrees locally — and shuffling MCP configurations and skill setups by hand — is painful. `jhgaylor/aod-ex` already does this for a single tenant, but it targets a different user; Fountain takes that core and rebuilds around multi-tenant use.

This repo is the bus for the [`captain-picard`](https://github.com/jhgaylor/aod-specs) Agent on Demand orchestrator. See `OPERATING_MODEL.md` for how the team operates and `ROADMAP.md` for what's open.

## Three surfaces

Every public feature lives on all three:

| Surface | Use it when |
|---|---|
| **Web UI** (`/dashboard`) | Getting started, debugging conversations, managing resources visually |
| **REST API** (`/api/*`) | Scripting, CI/CD pipelines, integrating Fountain into your own tools |
| **CLI** (`fountain`) | Local workflows, manifest-driven `apply`, shell scripting |

The CLI is a convenience wrapper over the REST API. Everything the CLI does, you can do with `curl`.

## Get started with the CLI

Install the `fountain` binary from the [Homebrew tap](https://github.com/BinaryBourbon/homebrew-tap):

```sh
brew install BinaryBourbon/tap/fountain
```

Log in against your Fountain instance:

```sh
fountain auth login
```

Apply a manifest. [`jhgaylor/agent-specs`](https://github.com/jhgaylor/agent-specs) is a public example tree of agents, environments, and vaults:

```sh
git clone https://github.com/jhgaylor/agent-specs
fountain apply -f agent-specs
```

`fountain apply` walks the directory and applies every `*.yml` / `*.yaml` doc that declares both `apiVersion` and `kind`. See [`cli/README.md`](cli/README.md) for the rest of the command surface.

## Use the API directly

### Authenticate

```sh
# Get a session token (email + password)
TOKEN=$(curl -sX POST https://founta.inevitable.fyi/api/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"..."}'  | jq -r .token)

# Or create a long-lived API key in the UI: Account → API Keys
# Then use it directly:
TOKEN=ft_your_api_key
```

### Manage resources

```sh
# Create an environment
curl -sX POST https://founta.inevitable.fyi/api/environments \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"python-data","networking_type":"unrestricted"}'

# Upsert a secret
curl -sX POST https://founta.inevitable.fyi/api/environments/$ENV_ID/secrets \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"key":"OPENAI_API_KEY","value":"sk-..."}'

# Create an agent
curl -sX POST https://founta.inevitable.fyi/api/agents \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"researcher","model":"anthropic/claude-sonnet-4-6","runtime":"claude","environment_id":"$ENV_ID"}'
```

### Run a conversation and stream output

```sh
# Start a conversation
CONV=$(curl -sX POST https://founta.inevitable.fyi/api/conversations \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"$AGENT_ID\",\"prompt\":\"Audit the auth module for security issues\"}")

CONV_ID=$(echo $CONV | jq -r .id)

# Stream log events (SSE)
curl -sN https://founta.inevitable.fyi/api/conversations/$CONV_ID/stream \
  -H "Authorization: Bearer $TOKEN"
```

Each SSE event is a JSON object: `{"kind":"output","stream":"stdout","data":"...","inserted_at":"..."}`.

### Explore the full API

Interactive Swagger UI: `https://founta.inevitable.fyi/api/docs`

OpenAPI spec: `https://founta.inevitable.fyi/api/openapi.json`

## Point an LLM at Fountain

Every Fountain instance serves a plain-text [`/llms.txt`](https://founta.inevitable.fyi/llms.txt), a bundled [`/llms-full.txt`](https://founta.inevitable.fyi/llms-full.txt), and a drop-in [`/skill`](https://founta.inevitable.fyi/skill) so any agentic IDE (Claude Code, Cursor, Continue, Aider, ...) can learn the API from one fetch:

```sh
mkdir -p ~/.claude/skills/fountain
curl -fsSL https://founta.inevitable.fyi/skill > ~/.claude/skills/fountain/SKILL.md
```

After that, telling Claude “spin up a researcher agent on Fountain and have it audit the auth module” Just Works — the skill describes the four primitives (Environment / Vault / Agent / Conversation), the CLI commands, the API endpoints, the SSE format, and the per-runtime result filters.

## Bootstrap a workstation

See [`SETUP.md`](SETUP.md) for the full local bootstrap (mise + Postgres + deps). The toolchain version is pinned in `.tool-versions` and mirrored in `render.yaml`, so a fresh laptop or ephemeral VM gets the same Erlang/Elixir as production.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for architecture, test patterns, tenant isolation contract, and things to avoid. See [`OPERATING_MODEL.md`](OPERATING_MODEL.md) for how the team operates.
