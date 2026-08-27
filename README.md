# Fountain

A multi-tenant API and UI for managing agents, repos, secrets, and conversations. It's for people who want to create sandboxed coding agent instances with preconfigured sets of env vars, MCP servers, skills, repos, and packages. Users treat Fountain as a building block for their own workflows, but also use the UI to get started and to debug. It exists because running Claude instances with worktrees locally — and shuffling MCP configurations and skill setups by hand — is painful.

## In one picture

<img src="docs/images/primitives.svg" alt="Three templates, one machine, in three stages. Stage one, write once: Agent, Environment and Vault are rows a tenant writes and reuses. Stage two, at launch: Fountain builds the machine, merges the Environment's secrets with the Vault's and the Vault wins, and starts the agent's runtime. Stage three, the machine: a sandbox holds the merged secrets as environment variables and runs one or more Conversations, each with its own transcript, on that one machine. The next turn lands on the same machine, an idle machine parks, and the concurrency ceiling reclaims it. On a hosted account with the egress broker on, the real values go to the broker instead, the sandbox gets a placeholder, and the sandbox reaches the internet only through the broker." width="740">

Agent, Environment and Vault are templates: rows you write once and use many
times. A Conversation is a run of an Agent on a machine that Fountain builds,
warms, meters and reclaims. Secrets merge at launch, the Vault winning; on a
hosted account with the egress broker on, a bound secret never enters the
sandbox at all. [The four primitives](docs/primitives.md) says why there are
four.

## Self-hosting

Run your own instance: [docs/self-hosting.md](docs/self-hosting.md).

```sh
cp .env.compose.example .env   # then fill in the generated keys
docker compose up -d
```

Prefer Kubernetes? A portable baseline — plain manifests, `kubectl apply -k`,
no operators assumed — lives in [`deploy/k8s/`](deploy/k8s/).

## The apps

Fountain's own UI is an operator console. You configure things in it; you do
not watch an agent work in it. The three apps we build for that are separate
single-page apps on their own origins, talking to `/api` with a key you paste
in or an OAuth sign-in. Each is static files, so a hosted build works against
your instance as soon as it admits the origin
(`API_CORS_ORIGINS=https://jakegaylor.com`).

| App | What it is | |
|---|---|---|
| [**Conversations**](https://github.com/jhgaylor/fountain-conversations) | ChatGPT, except the model has a real computer and you can watch it use one: start a run, follow it turn by turn, steer it, read the raw log. | [Open it](https://jakegaylor.com/fountain-conversations/) |
| [**Team**](https://github.com/jhgaylor/fountain-team) | A group chat whose contacts are agents you made, one click each: roster on the left, thread on the right, routines on a schedule. | [Open it](https://jakegaylor.com/fountain-team/) |
| [**Workbench**](https://github.com/jhgaylor/fountain-workbench) | Multiplayer engineering: projects over an environment and a vault, work items in them, and teammates you put on a work item by typing. | [Open it](https://workbench.inevitable.fyi) |

`CONVERSATIONS_APP_URL` and `TEAM_APP_URL` point the console's own links at
copies you host. [The console, the apps, and the API](docs/concepts/surfaces.md)
says why the line is drawn there, and
[Built with Fountain](https://managoat.com/built-with) has the rest of the
applications built on this API.

## Four surfaces

Every public feature lives on the first three; the SDK wraps the verbs most
code actually reaches for.

| Surface | Use it when |
|---|---|
| **Web UI** (`/dashboard`) | Getting started, managing agents, environments, vaults, keys and audit visually |
| **REST API** (`/api/*`) | Scripting, CI/CD pipelines, integrating Fountain into your own tools |
| **CLI** (`fountain`) | Local workflows, manifest-driven `apply`, shell scripting |
| **TypeScript SDK** (`@agentshit/fountain-sdk`) | Running an agent from your own code: `fountain.run(prompt, { agent, vault })` |

The CLI and the SDK are convenience wrappers over the REST API. Everything they do, you can do with `curl`.

```bash
npm install @agentshit/fountain-sdk
```

```ts
import { Fountain } from "@agentshit/fountain-sdk";

const run = await new Fountain().run("Upgrade us to Phoenix 1.8 and open a PR", {
  agent: "reposage",
  vault: "github-bot",   // the token lands in the sandbox, never in the prompt
});

console.log(run.text, run.url);
```

The sandbox is still there afterwards: `fountain.resume(run.conversationId).send("...")`
continues on the same machine, with the same checkout and the same session.
See [`sdk/typescript/`](sdk/typescript/) or the [SDK docs](https://managoat.com/docs/sdk).

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

The examples below run against your own instance — point `FOUNTAIN_URL` at it
(`http://localhost:4000` for the compose quick start):

```sh
FOUNTAIN_URL=http://localhost:4000
```

### Authenticate

```sh
# Get a session token (email + password)
TOKEN=$(curl -sX POST $FOUNTAIN_URL/api/auth/token \
  -H 'Content-Type: application/json' \
  -d '{"email":"you@example.com","password":"..."}'  | jq -r .token)

# Or create a long-lived API key in the UI: Account → API Keys
# Then use it directly:
TOKEN=ftn_your_api_key
```

### Manage resources

```sh
# Create an environment
curl -sX POST $FOUNTAIN_URL/api/environments \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"python-data","networking_type":"unrestricted"}'

# Upsert a secret
curl -sX POST $FOUNTAIN_URL/api/environments/$ENV_ID/secrets \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"key":"OPENAI_API_KEY","value":"sk-..."}'

# Create an agent
curl -sX POST $FOUNTAIN_URL/api/agents \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"name":"researcher","model":"anthropic/claude-sonnet-4-6","runtime":"claude","environment_id":"$ENV_ID"}'
```

### Run a conversation and stream output

```sh
# Start a conversation
CONV=$(curl -sX POST $FOUNTAIN_URL/api/conversations \
  -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/json' \
  -d "{\"agent_id\":\"$AGENT_ID\",\"prompt\":\"Audit the auth module for security issues\"}")

CONV_ID=$(echo $CONV | jq -r .id)

# Stream log events (SSE)
curl -sN $FOUNTAIN_URL/api/conversations/$CONV_ID/stream \
  -H "Authorization: Bearer $TOKEN"
```

Each SSE event is a JSON object:
`{"kind":"output","stream":"stdout","data":"...","stage":"turn","state":null,"turn_id":"...","ts":"..."}`
— the timestamp key on the wire is `ts`, and `stage`/`state`/`turn_id` let a
client group output under its owning stage without inferring it from event
interleaving.

### Explore the full API

Interactive Swagger UI: `$FOUNTAIN_URL/api/docs`

OpenAPI spec: `$FOUNTAIN_URL/api/openapi.json`

## Point an LLM at Fountain

Every Fountain instance serves a plain-text `/llms.txt`, a bundled `/llms-full.txt`, and a drop-in `/skill` so any agentic IDE (Claude Code, Cursor, Continue, Aider, ...) can learn the API from one fetch:

```sh
mkdir -p ~/.claude/skills/fountain
curl -fsSL $FOUNTAIN_URL/skill > ~/.claude/skills/fountain/SKILL.md
```

After that, telling Claude “spin up a researcher agent on Fountain and have it audit the auth module” Just Works — the skill describes the four primitives (Environment / Vault / Agent / Conversation), the CLI commands, the API endpoints, the SSE format, and the per-runtime result filters.

## Bootstrap a workstation

See [`SETUP.md`](SETUP.md) for the full local bootstrap (mise + Postgres + deps). The local toolchain is pinned in `.tool-versions` (via mise), so a fresh laptop or ephemeral VM gets the same Erlang/Elixir as everyone else. Production images build from the repo-root `Dockerfile`, whose `hexpm/elixir` base pins the production toolchain — a toolchain bump must update both `.tool-versions` and the Dockerfile; see the parity reference in `SETUP.md`.

## Contributing

See [`CLAUDE.md`](CLAUDE.md) for architecture, test patterns, the tenant isolation contract, and things to avoid. Architecturally significant choices are recorded as ADRs in [`decisions/`](decisions/).

## Licence

Fountain is not licensed as a single unit. The short version:

| What | Licence | What it means for you |
|---|---|---|
| The server (`apps/fountain`) | [AGPL-3.0-or-later](LICENSE) | Run it, modify it, host it. If you host a modified version, your users are entitled to your source |
| [`ee/`](ee/) — Stripe billing and growth email | [Elastic Licence 2.0](ee/LICENSE) | Free to run in your own instance, changes stay yours. You may not offer it to third parties as a hosted service |
| [`cli/`](cli/), [`sdk/typescript`](sdk/typescript) | [Apache-2.0](cli/LICENSE) | Build on the API, ship the CLI inside a proprietary product, no obligations |

The client surfaces are permissive on purpose. Integrating with Fountain
should never put a licence obligation on your application, and an AGPL SDK
would do exactly that.

The copyleft is aimed at one thing: a company that improves Fountain and runs
it as a service owes those improvements back to everyone else running it. It
does not stop anyone hosting Fountain commercially, including in competition
with the hosted product. It stops them doing it in private.

The hosted instance at [managoat.com](https://managoat.com) is one
instance of this code under the name Managoat; the project keeps the name
Fountain. The long form of the split, and where everything lives, is
[docs/open-source.md](docs/open-source.md), published at `/docs/open-source`
(`decisions/0034-project-site-is-the-product-site.md` says why there is no
separate project site).

See [`NOTICE`](NOTICE) for third-party attribution,
[`CONTRIBUTING.md`](CONTRIBUTING.md) for how the licences apply to
contributions, and
[`decisions/0027-agpl-relicensing.md`](decisions/0027-agpl-relicensing.md) for
the reasoning.
