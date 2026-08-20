# TypeScript SDK

The REST API describes machinery: conversations, turns, log events, blocks. The
SDK describes the job.

```ts
import { Fountain } from "fountain-sdk";

const fountain = new Fountain();

const run = await fountain.run("Upgrade us to Phoenix 1.8 and open a PR", {
  agent: "reposage",
  vault: "github-bot",   // the token lands in the sandbox, never in the prompt
});

console.log(run.text);   // what the agent said
console.log(run.url);    // where a human can watch it happen
```

The source lives in [`sdk/typescript/`](https://github.com/BinaryBourbon/fountain/tree/main/sdk/typescript).
It has no runtime dependencies and needs Node 20.19 or newer.

!!! note "Not on npm yet"

    The package is not yet published. Until it is, build it from a checkout —
    `cd sdk/typescript && npm install && npm run build && npm link` — and
    `npm link fountain-sdk` in the project that wants it.

## What the second argument is for

The first argument is a prompt, which every LLM SDK has. The second is the part
that is Fountain:

| | what it does |
|---|---|
| `agent` | which named agent config to run — its runtime, model, skills and MCP servers |
| `environment` | which baseline to provision the sandbox from: packages, cloned repos, setup scripts |
| `vault` | which secrets to attach at spawn. They win over the environment's on a key collision |

A vault's values are decrypted into the sandbox's environment when the sandbox
spawns. They are not in the prompt, not in the model's context and not in the
log feed the SDK reads. Swapping `vault: "github-bot"` for
`vault: "github-readonly"` changes what the agent is able to do without
changing a word of the task.

There is a second layer under that, and it is worth knowing about because it
changes what you can safely let an agent do: Fountain redacts every value of 8
bytes or more that it placed in the sandbox's environment out of the
conversation's output, on the single write path every log event goes through.
An `env`, a `set -x`, a `cat .env`, or an agent simply asked to print its token
persists as `[REDACTED]`. The secret reaches the process that needs it and not
the transcript, the database, or this SDK.

See [the four primitives](primitives.md) for what each one is.

## Credentials

`new Fountain()` resolves exactly as the [CLI](cli.md) does, so a script
inherits whatever already works in your terminal:

```
apiKey:  option → FOUNTAIN_API_KEY → FOUNTAIN_TOKEN → ~/.fountain/credentials
baseUrl: option → FOUNTAIN_BASE_URL → ~/.fountain/credentials → hosted
```

`FOUNTAIN_TOKEN` is the conversation-scoped token a Fountain sandbox exports
for the agent inside it. An agent that imports this SDK therefore delegates
with the credential it already holds, and the conversations it opens are
recorded as its children — fan-out needs no extra configuration.

## Awaiting, streaming, or neither

`run()` starts the work and returns a handle. There is no second request behind
any of these — they are three views of one run.

```ts
// the finished answer
const result = await fountain.run(prompt, { agent: "reposage" });

// the words, as they arrive
const run = fountain.run(prompt, { agent: "reposage" });
for await (const chunk of run.textStream) process.stdout.write(chunk);

// everything: lifecycle, tools, thinking, raw events
for await (const event of run) {
  if (event.type === "tool") console.log("→", event.name);
}

// fan out: nothing is awaited, so every sandbox provisions at once
const results = await Promise.all(agents.map((agent) => fountain.run(prompt, { agent })));
```

A turn that **fails** is a result, not an exception — check `result.state`
(`done`, `failed`, `interrupted`, `timeout`). Only a transport failure, a
rejected request or a timeout throws.

## A whole definition, in code

`run()` names an agent. This is where the agent comes from — and the point of
showing it whole is that the vocabulary is small enough to fit on one screen.

```ts
const environment = await fountain.environments.create({
  name: "fountain-ci",
  packages: { apt: ["ripgrep"] },
  env_vars: { MIX_ENV: "test" },
  repositories: [
    { url: "https://github.com/BinaryBourbon/fountain", mount_path: "/work/fountain" },
  ],
  setup_script: "cd /work/fountain && mix deps.get",
  networking_type: "limited",
  networking_config: { allowed_hosts: ["github.com", "hex.pm", "api.anthropic.com"] },
});

const vault = await fountain.vaults.create({ name: "github-bot" });
await fountain.vaults.secrets.set("github-bot", "GITHUB_TOKEN", process.env.GITHUB_TOKEN!);

const agent = await fountain.agents.create({
  name: "reposage",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  description: "Reads a repository and answers questions about it",
  system: "You are a careful reader of other people's code.",
  environment_id: environment.id,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: [vault.id],
});

// ...and now the one-liner at the top of this page has something to run.
await fountain.run("Find every N+1 query and open a PR", {
  agent: "reposage",
  vault: "github-bot",
});
```

That is an [environment](primitives.md), a [vault](primitives.md) and an
[agent](primitives.md) — three of the four primitives — and then a
conversation, which is the fourth.

The fields that are not self-evident:

| Field | What it decides |
|---|---|
| `runtime` | `claude`, `codex`, `gemini` or `opencode`. `model`'s provider must match it |
| `model` | canonical `provider/model_id`. Not checked against a list, so a model released today works today |
| `system` | the agent's system prompt |
| `skills` | either `{ source, ref? }` (installed from GitHub) or `{ name, content }` (written into the sandbox verbatim) — exactly one shape per entry |
| `sandbox_provider` | `sprites`, `e2b`, `daytona` or `runner`; `null` takes the instance default |
| `allowed_vault_ids` | which vaults a conversation may attach. `null` allows any, `[]` forbids all, a list is an allowlist. Since vault values override the environment, this is what scopes who can override reviewed config |
| `allowed_environment_ids` | same shape, for launching the agent under a different environment |

Every collection reads the same way:

```ts
await fountain.agents.list();                                  // or .list("search")
await fountain.agents.get("reposage");                         // by name or id
await fountain.agents.update("reposage", { model: "anthropic/claude-opus-5" });
await fountain.agents.delete("reposage");
```

`environments` and `vaults` have the same five verbs, plus `secrets`:

```ts
await fountain.environments.secrets.set("fountain-ci", "HEX_API_KEY", "…");
await fountain.vaults.secrets.setAll("github-bot", { GITHUB_TOKEN: "…", GITHUB_USER: "bot" });
await fountain.vaults.secrets.list("github-bot");    // keys only — never values
await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

Secret values are write-only. `list` returns the keys and nothing else: the SDK
can put a credential into a sandbox and cannot read it back out.

!!! note "Why `environment_id` and not `environmentId`"

    Resource payloads use the API's own key names, so one definition reads
    identically in the SDK, in the [REST API](api.md) and in a `fountain.yml`
    manifest, and this page doubles as the API reference. Options that control
    the SDK's own behaviour — `timeoutMs`, `signal` — are camelCase, because
    those are not data.

## Follow-ups

```ts
const first = await fountain.run("Find every N+1 query in this repo", { agent: "reposage" });
const second = await fountain.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine, the checkout
is where the first turn left it, and the agent's session still holds what it
learned. A [suspended](operations.md) sandbox wakes for it.

## Timeouts

`run()` waits as long as the turn takes; agent work legitimately runs for
hours. `timeoutMs` stops the *waiting* — never the agent:

```ts
try {
  await fountain.run(prompt, { agent: "reposage", timeoutMs: 5 * 60_000 });
} catch (error) {
  if (error instanceof TimeoutError) {
    console.log(error.partialText);
    await fountain.resume(error.conversationId).send("status?");
  }
}
```

`run.interrupt()` asks the agent to stop the turn and leaves the sandbox up;
`run.terminate()` tears the sandbox down.

## Everything else

The SDK wraps the verbs worth wrapping. The rest of the API — audit, schedules,
the team, API keys, conversations' images and trees — is one call away with the
same auth and error handling:

```ts
await fountain.request("GET", "/api/audit", { query: { limit: 50 } });
```

The [API reference](api.md) and the generated `GET /api/openapi.json` cover
those.

## Other languages

There is no SDK for your language yet, but there are two worked references for
the part that is easy to get wrong — following a turn through the log feed:

- **Python** — the [Hermes plugin](integrations/hermes.md)'s `tools.py`, which
  polls `/events?blocks=true`.
- **Go** — the [`fountain` CLI](cli.md)'s `fountain run`, which streams SSE.

Both implement the same rules the TypeScript SDK does: keep only your own
turn's events, keep only `text` blocks, join ACP chunks with nothing and legacy
rows as paragraphs, start a new paragraph after a tool call, and resume from
the last event id when a connection drops mid-turn.
