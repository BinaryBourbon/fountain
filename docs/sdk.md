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

    The package is not yet published. Until it is, build it from a checkout
    with `cd sdk/typescript && npm install && npm run build && npm link`, and
    `npm link fountain-sdk` in the project that wants it.

## What the second argument is for

The first argument is a prompt, which every LLM SDK has. The second is the part
that is Fountain:

| | what it does |
|---|---|
| `agent` | which named agent config to run, meaning its runtime, model, skills and MCP servers |
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
An `env`, a `set -x`, a `cat .env`, or an agent asked outright to print its token
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
recorded as its children, so fan-out needs no extra configuration.

## Awaiting, streaming, or neither

`run()` starts the work and returns a handle. There is no second request behind
any of these, because they are three views of one run.

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

A turn that **fails** is a result rather than an exception, so check `result.state`
(`done`, `failed`, `interrupted`, `timeout`). Only a transport failure, a
rejected request or a timeout throws.

## A whole definition, in code

`run()` names an agent. This is where the agent comes from, and the point of
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
[agent](primitives.md), three of the four primitives, and then a
conversation, which is the fourth.

The fields that are not self-evident:

| Field | What it decides |
|---|---|
| `runtime` | `claude`, `codex`, `gemini` or `opencode`. `model`'s provider must match it |
| `model` | canonical `provider/model_id`. Not checked against a list, so a model released today works today |
| `system` | the agent's system prompt |
| `skills` | either `{ source, ref? }` (installed from GitHub) or `{ name, content }` (written into the sandbox verbatim). Exactly one shape per entry |
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
await fountain.vaults.secrets.list("github-bot");    // keys only, never values
await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

Secret values are write-only. `list` returns the keys and nothing else: the SDK
can put a credential into a sandbox and cannot read it back out.

!!! note "Why `environment_id` and not `environmentId`"

    Resource payloads use the API's own key names, so one definition reads
    identically in the SDK, in the [REST API](api.md) and in a `fountain.yml`
    manifest, and this page doubles as the API reference. Options that control
    the SDK's own behaviour (`timeoutMs`, `signal`) are camelCase, because
    those are not data.

## The team

Ten of the eleven applications built on Fountain talk to `/api/team`, and some
of them never touch `/api/conversations` at all. The reason is that a teammate
is a *durable* thing, meaning one agent, one long-running sandbox and one
thread you keep messaging, where a conversation is something you open and
close.

```ts
await fountain.team.add("watchtower", { name: "Watchtower" });

const reply = await fountain.team.message("watchtower", "Any disks over 80%?");
console.log(reply.text);
```

`message()` returns the same `Run` handle `run()` does: await it, iterate it,
or ignore it and let the stream below carry the answer to your UI.

An entire messaging client on these verbs, covering roster, threads,
connectors, routines and what each piece is doing, is
[**Build a chat app**](build/index.md).

```ts
await fountain.team.list();                       // the roster, with unread counts
await fountain.team.rename("watchtower", "Eyes"); // null restores the agent's name
await fountain.team.history("watchtower");        // every thread it has had
await fountain.team.freshConversation("watchtower"); // new computer, old one retired
await fountain.team.remove("watchtower");         // off the team; the agent stays
```

Routines are cron for a teammate:

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

The stream reconnects from its last event id on its own, so a deploy or an
idle timeout is invisible to the caller.

!!! note "The team stream carries raw events"

    `/api/team/stream` takes `streams` and nothing else, with no `blocks`, so
    events on it are the runtime's own dialect. Treat it as a notification
    channel (something happened, to whom) and read the detail from the
    conversation's own feed, which does parse blocks. `fountain.events()` is
    the same idea across every conversation you own, and *does* take `blocks`.

## Reading a thread

Two calls cover what every application does when someone opens a thread:

```ts
const conversation = fountain.resume(conversationId);

const events = await conversation.history({ streams: ["acp", "stage"] });  // paged until drained
await conversation.markRead();                                            // clears the unread badge
```

`history()` pages the log feed to the end for you; every one of the eleven apps
wrote that loop by hand first.

## Follow-ups

```ts
const first = await fountain.run("Find every N+1 query in this repo", { agent: "reposage" });
const second = await fountain.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine, the checkout
is where the first turn left it, and the agent's session still holds what it
learned. A [suspended](reference/conversation-states.md) sandbox wakes for it.

## Timeouts

`run()` waits as long as the turn takes; agent work legitimately runs for
hours. `timeoutMs` stops the *waiting*, never the agent.

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

## Errors

Branch on `code`, not on the status. `conversation_busy` is a 400,
`sandbox_quota_exceeded` is a 429 and `provisioning` is a 503, and what you
want to say about each has nothing to do with those numbers.

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
| `ConversationBusyError` | `conversation_busy` (400) | yes, the turn in flight has to finish |
| `NotReadyError` | `provisioning`, `sprite_probe_failed` (503) | yes, carries the server's `Retry-After` |
| `QuotaExceededError` | `sandbox_quota_exceeded` (429) | yes, terminate a conversation first |
| `SubscriptionRequiredError` | `subscription_required` (402) | no, carries `upgradeUrl` |
| `ValidationError` | 422 | no, read `fieldErrors` |
| `AuthError` / `NotFoundError` | 401 / 404 | no |
| `ConnectionError` | never reached the server | in a browser, usually CORS |

Every one carries `status`, `code`, `body`, `retryAfter` and a `retryable`
flag, so a generic retry wrapper needs no table of its own.

## In a browser

The SDK's default entry pulls in no Node built-in, so it bundles as-is; the
credentials-file reader lives behind the `node` export condition. In a browser
you pass what you have:

```ts
const fountain = new Fountain({ baseUrl, apiKey });   // from your own settings UI
```

The server must allow your origin through `API_CORS_ORIGINS`, or every call fails
before it starts. `ConnectionError` says exactly that, because "Failed to
fetch" has sent more than one person hunting through their own code.

## Everything else

The SDK wraps the verbs worth wrapping. The rest of the API, including audit,
API keys, admin, billing and exports, is one call away with the same auth and
error
handling:

```ts
await fountain.request("GET", "/api/audit", { query: { limit: 50 } });
```

The [API reference](api.md) and the generated `GET /api/openapi.json` cover
those.

## Generated underneath

The types are not hand-written. `src/generated/openapi.ts` comes from the same
OpenAPI document the server serves at `GET /api/openapi.json`, and CI
regenerates it and fails on a diff, so a field added to a schema in Elixir
reaches the SDK on the next build, and a type here can never describe an API
that no longer exists.

```ts
import type { components, paths } from "fountain-sdk";

type Teammate = components["schemas"]["Teammate"];
```

What is hand-written is the part a spec cannot express: that many log events
fold into one *turn*, that a run can be awaited or streamed, and which of 85
paths are worth a verb.

## Other languages

There is no SDK for your language yet, but there are two worked references for
the part that is easy to get wrong, which is following a turn through the log
feed.

- **Python**, the [Hermes plugin](integrations/hermes.md)'s `tools.py`, which
  polls `/events?blocks=true`.
- **Go**, the [`fountain` CLI](cli.md)'s `fountain run`, which streams SSE.

Both implement the same rules the TypeScript SDK does: keep only your own
turn's events, keep only `text` blocks, join ACP chunks with nothing and legacy
rows as paragraphs, start a new paragraph after a tool call, and resume from
the last event id when a connection drops mid-turn.
