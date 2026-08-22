# TypeScript SDK

The REST API describes machinery. Conversations, turns, log events, blocks.
The SDK describes the job.

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

The source lives in
[`sdk/typescript/`](https://github.com/BinaryBourbon/fountain/tree/main/sdk/typescript).
It has no runtime dependency, and it needs Node 20.19 or newer.

!!! note "Not on npm yet"

    Nobody has published the package yet. Until somebody does, build it from a
    checkout with
    `cd sdk/typescript && npm install && npm run build && npm link`. Then run
    `npm link fountain-sdk` in the project that wants it.

## What the second argument is for

The first argument is a prompt, and each LLM SDK has one. The second argument
is the part that is Fountain.

| | what it does |
|---|---|
| `agent` | Which named agent config to run. That is its runtime, model, skills and MCP servers. |
| `environment` | Which baseline to provision the sandbox from. That is the packages, the cloned repos and the setup script. |
| `vault` | Which secrets to attach at spawn. They win over the environment's on a key collision. |

Fountain decrypts a vault's values into the sandbox's environment when the
sandbox spawns. They are not in the prompt, not in the model's context, and
not in the log feed the SDK reads.

Change `vault: "github-bot"` to `vault: "github-readonly"`, and you change
what the agent can do. You change not one word of the task.

There is a second layer under that, and it changes what you can safely let an
agent do.

Fountain redacts each value of 8 bytes or more that it placed in the sandbox's
environment out of the conversation's output. It does that on the one write
path that each log event takes.

An `env`, a `set -x`, a `cat .env`, and an agent that you ask outright to
print its token all persist as `[REDACTED]`. The secret reaches the process
that needs it. It reaches neither the transcript, nor the database, nor this
SDK.

Read [the four primitives](primitives.md) for what each one is.

## Credentials

`new Fountain()` resolves exactly as the [CLI](cli.md) does. So a script
inherits whatever already works in your terminal.

```
apiKey:  option → FOUNTAIN_API_KEY → FOUNTAIN_TOKEN → ~/.fountain/credentials
baseUrl: option → FOUNTAIN_BASE_URL → ~/.fountain/credentials → hosted
```

`FOUNTAIN_TOKEN` is the token that a Fountain sandbox exports for the agent
inside it, scoped to that one conversation.

So an agent that imports this SDK delegates with the credential it already
holds. Fountain records the conversations it opens as its children. Fan-out
therefore needs no more configuration.

## Awaiting, streaming, or neither

`run()` starts the work and returns a handle. No second request hides behind
any of these. They are three views of one run.

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

A turn that **fails** is a result, and not an exception. So check
`result.state`, which is `done`, `failed`, `interrupted` or `timeout`. Only a
transport failure, a request the server rejected, or a timeout throws.

## A whole definition, in code

`run()` names an agent. Here is where that agent comes from. The point of the
whole definition is that the vocabulary fits on one screen.

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
[agent](primitives.md). Those are three of the four primitives. The
conversation is the fourth.

Here are the fields that need a word.

| Field | What it decides |
|---|---|
| `runtime` | `claude`, `codex`, `gemini` or `opencode`. The provider in `model` must match it. |
| `model` | The canonical `provider/model_id`. Fountain checks it against no list, so a model that ships today works today. |
| `system` | The agent's system prompt. |
| `skills` | Either `{ source, ref? }`, which installs from GitHub, or `{ name, content }`, which Fountain writes into the sandbox word for word. Each entry takes exactly one shape. |
| `sandbox_provider` | `sprites`, `e2b`, `daytona` or `runner`. A `null` takes the instance default. |
| `allowed_vault_ids` | Which vaults a conversation can attach. A `null` permits each one, `[]` permits none, and a list is an allowlist. A vault value overrides the environment, so this is what scopes who can override a config that somebody reviewed. |
| `allowed_environment_ids` | The same shape. It covers a launch of the agent under a different environment. |

Each collection reads the same way.

```ts
await fountain.agents.list();                                  // or .list("search")
await fountain.agents.get("reposage");                         // by name or id
await fountain.agents.update("reposage", { model: "anthropic/claude-opus-5" });
await fountain.agents.delete("reposage");
```

`environments` and `vaults` have the same five verbs, and `secrets` as well.

```ts
await fountain.environments.secrets.set("fountain-ci", "HEX_API_KEY", "…");
await fountain.vaults.secrets.setAll("github-bot", { GITHUB_TOKEN: "…", GITHUB_USER: "bot" });
await fountain.vaults.secrets.list("github-bot");    // keys only, never values
await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

A secret value is write-only. `list` returns the keys and nothing else. The
SDK can put a credential into a sandbox, and it cannot read one back out.

!!! note "Why `environment_id` and not `environmentId`"

    A resource payload uses the API's own key names. So one definition reads
    the same way in the SDK, in the [REST API](api.md) and in a
    `fountain.yml` manifest, and this page doubles as the API reference.

    An option that controls the SDK's own behaviour is camelCase. `timeoutMs`
    and `signal` are the two, and neither one is data.

## The team

Ten of the eleven applications on Fountain talk to `/api/team`, and some of
them never touch `/api/conversations` at all.

The reason is that a teammate *lasts*. It is one agent, one sandbox that stays
up, and one thread that you send to again and again. A conversation is
something you open and close.

```ts
await fountain.team.add("watchtower", { name: "Watchtower" });

const reply = await fountain.team.message("watchtower", "Any disks over 80%?");
console.log(reply.text);
```

`message()` returns the same `Run` handle that `run()` does. Await it, iterate
it, or ignore it and let the stream below carry the answer to your UI.

[**Build a chat app**](build/index.md) writes a whole chat client on these
verbs. It covers the roster, threads, connectors, routines, and the job each
piece does.

```ts
await fountain.team.list();                       // the roster, with unread counts
await fountain.team.rename("watchtower", "Eyes"); // null restores the agent's name
await fountain.team.history("watchtower");        // every thread it has had
await fountain.team.freshConversation("watchtower"); // new computer, old one retired
await fountain.team.remove("watchtower");         // off the team; the agent stays
```

A routine is cron for a teammate.

```ts
await fountain.team.schedules.create("watchtower", {
  cron: "0 9 * * *",
  prompt: "Check disk usage and say only what changed.",
});
```

### One stream for everyone

```ts
for await (const event of fountain.team.stream({ streams: ["stage"] })) {
  if (event.stage === "turn" && event.state === "done") refreshRoster();
}
```

The stream reconnects from its last event id on its own. So the caller sees
neither a deploy nor an idle timeout.

!!! note "The team stream carries blocks"

    `/api/team/stream` takes `blocks` and `streams`. The SDK sends `blocks` for
    you, so an event on it arrives parsed, not in the runtime's own dialect.
    The stream covers many conversations, so the server picks the runtime per
    event from the conversation that produced it.

    You can therefore render a thread from this one connection.
    `fountain.events()` is the same idea across each conversation you own.

## Reading a thread

Two calls cover what each application does when somebody opens a thread.

```ts
const conversation = fountain.resume(conversationId);

const events = await conversation.history({ streams: ["acp", "stage"] });  // paged until drained
await conversation.markRead();                                            // clears the unread badge
```

`history()` pages the log feed to the end for you. Each of the eleven apps
wrote that loop by hand first.

## Follow-ups

```ts
const first = await fountain.run("Find every N+1 query in this repo", { agent: "reposage" });
const second = await fountain.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine. The
checkout is where the first turn left it, and the agent's session still holds
what it learned. A [suspended](reference/conversation-states.md) sandbox wakes
for it.

## Timeouts

`run()` waits as long as the turn takes, and agent work fairly runs for hours.
`timeoutMs` stops the *wait*, and never the agent.

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

`run.interrupt()` asks the agent to stop the turn, and leaves the sandbox up.
`run.terminate()` takes the sandbox down.

## Errors

Branch on `code`, and not on the status. `conversation_busy` is a 400,
`sandbox_quota_exceeded` is a 429, and `provisioning` is a 503. What you want
to say about each one has nothing to do with those numbers.

```ts
try {
  await fountain.team.message("watchtower", prompt);
} catch (error) {
  if (error instanceof ConversationBusyError) return "Still working on the last one.";
  if (error instanceof QuotaExceededError) return `Sandboxes full (${error.activeSandboxes}/${error.limit}).`;
  if (error instanceof NotReadyError) return `Starting up, retry in ${error.retryAfter}s.`;
  if (error instanceof ValidationError) return Object.entries(error.fieldErrors)[0]?.join(" ");
  throw error;
}
```

| Class | Code / status | Retryable |
|---|---|---|
| `ConversationBusyError` | `conversation_busy` (400) | Yes. The turn in flight must finish. |
| `NotReadyError` | `provisioning`, `sprite_probe_failed` (503) | Yes. It carries the server's `Retry-After`. |
| `QuotaExceededError` | `sandbox_quota_exceeded` (429) | Yes. Terminate a conversation first. |
| `SubscriptionRequiredError` | `subscription_required` (402) | No. It carries `upgradeUrl`. |
| `ValidationError` | 422 | No. Read `fieldErrors`. |
| `AuthError` and `NotFoundError` | 401 and 404 | No. |
| `ConnectionError` | It never reached the server. | In a browser, the cause is usually CORS. |

Each one carries `status`, `code`, `body`, `retryAfter` and a `retryable`
flag. So a generic retry wrapper needs no table of its own.

## In a browser

The SDK's default entry pulls in no Node built-in, so it bundles as it is. The
reader for the credentials file sits behind the `node` export condition.

In a browser you pass what you have.

```ts
const fountain = new Fountain({ baseUrl, apiKey });   // from your own settings UI
```

The server must admit your origin through `API_CORS_ORIGINS`. Otherwise each
call fails before it starts.

`ConnectionError` says exactly that. "Failed to fetch" has sent more than one
person to search their own code for an hour.

## Everything else

The SDK wraps the verbs that are worth a wrapper. The rest of the API is one
call away, with the same auth and the same errors. That rest is audit, API
keys, admin, payment and exports.

```ts
await fountain.request("GET", "/api/audit", { query: { limit: 50 } });
```

The [API reference](api.md) covers those, and so does the generated
`GET /api/openapi.json`.

## Generated underneath

Nobody writes the types by hand. `src/generated/openapi.ts` comes from the
OpenAPI document that the server serves at `GET /api/openapi.json`.

CI generates it again and fails on a diff. So a field that somebody adds to a
schema in Elixir reaches the SDK on the next build. A type here can never
describe an API that has gone.

```ts
import type { components, paths } from "fountain-sdk";

type Teammate = components["schemas"]["Teammate"];
```

What people write by hand is the part a spec cannot express. That many log
events fold into one *turn*. That you can await a run or stream it. Which of
85 paths are worth a verb.

## Other languages

There is no SDK for your language yet. There are two worked references for the
part that is easy to get wrong, which is how to follow a turn through the log
feed.

- **Python.** The [Hermes plugin](integrations/hermes.md)'s `tools.py`, which
  polls `/events?blocks=true`.
- **Go.** The [`fountain` CLI](cli.md)'s `fountain run`, which streams SSE.

The two of them implement the rules that the TypeScript SDK implements. Keep
your own turn's events, and no other. Keep the `text` blocks, and no other
kind. Join the ACP chunks with nothing, and the legacy rows as paragraphs.
Start a new paragraph after a tool call. Resume from the last event id when a
connection drops mid-turn.
