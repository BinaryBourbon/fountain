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

The SDK wraps the verbs worth wrapping. The rest of the API — environments,
secrets, audit, schedules, the team, API keys — is one call away with the same
auth and error handling:

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
