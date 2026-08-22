# fountain-sdk

Give an agent a computer, your repos and your credentials — in one call.

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

That is the whole thing. The agent ran on a real machine with your repository
cloned and your GitHub token attached at spawn time, and the machine is still
there when you want to ask it something else.

## Why not just call a model?

A model API takes a prompt and returns tokens. To make it do work you supply
the computer, the checkout, the tools and the secrets — and you keep supplying
them, on every call, because nothing persists between them.

Fountain's unit is not a message. It is **a sandbox with an agent in it**:

| | model API | `fountain.run()` |
|---|---|---|
| where it runs | your process | an isolated sandbox, provisioned per run |
| your repo | you paste it in | already cloned, from the **environment** |
| your secrets | in the prompt, or in your process | attached at spawn from a **vault**, never in the transcript |
| the next question | resend the whole context | `resume(id).send("...")` — same machine, same session |
| watching it | your logs | `run.url`, a live transcript |

`vault` is the argument to look at. Its values are decrypted into the sandbox's
environment when the sandbox spawns; they are never part of the prompt, never
in the model's context, and never in the log feed this SDK reads. Swapping
`vault: "github-bot"` for `vault: "github-readonly"` changes what the agent can
do without changing a word of the task.

There is a second layer under that, and it is worth knowing about because it
changes what you can safely let an agent do: Fountain redacts every value of 8
bytes or more that it placed in the sandbox's environment out of the
conversation's output, on the single write path every log event goes through.
An `env`, a `set -x`, a `cat .env`, or an agent simply asked to print its token
persists as `[REDACTED]`. The secret reaches the process that needs it and not
the transcript, the database, or this SDK.

## What it replaces

Every integration that ever talked to Fountain wrote the same wrapper first —
open a conversation, send the prompt, follow the log feed, decide when the turn
is over, glue the text back together. This is that wrapper, once:

<details>
<summary>The same run, by hand</summary>

```bash
# 1. find the agent, the vault, the environment (three listings, by name)
curl -sH "$AUTH" $BASE/api/agents | jq -r '.data[] | select(.name=="reposage") | .id'
curl -sH "$AUTH" $BASE/api/vaults | jq -r '.data[] | select(.name=="github-bot") | .id'

# 2. open the conversation
CONV=$(curl -sH "$AUTH" -H 'Content-Type: application/json' \
  -d '{"agent_id":"...","vault_id":"...","prompt":"Upgrade us to Phoenix 1.8"}' \
  $BASE/api/conversations | jq -r .data.id)

# 3. follow the feed — and now the real work starts:
#    - page /events?blocks=true&after=N until has_more is false
#    - keep only events whose turn_id is *your* turn's
#    - keep only `text` blocks; `tool_use` is not the answer, `thinking` is not either
#    - join acp chunks with nothing, stdout rows with a blank line,
#      and start a new paragraph after any tool call
#    - stop on stage/turn/done — or failed, or interrupted
#    - and when the connection drops mid-turn, resume from the last event id
#      or you will either miss output or replay it twice
curl -sH "$AUTH" "$BASE/api/conversations/$CONV/stream?blocks=true" | ...
```

</details>

Those rules are not incidental complexity you could skip — get the paragraph
rule wrong and every transcript reads as one run-on sentence; get the cursor
wrong and a deploy mid-turn silently drops the answer. They are in here, with
tests.

## Install

**Not on npm yet.** Until it is published, install it from a checkout:

```bash
cd sdk/typescript && npm install && npm run build && npm link
npm link fountain-sdk            # in the project that wants it
```

Once published, it will be `npm install fountain-sdk`.

Node 20.19+ (native `fetch` and ESM). No runtime dependencies.

## Credentials

`new Fountain()` resolves the same way the `fountain` CLI does, so a script
inherits whatever already works in your terminal:

```
apiKey:  option → FOUNTAIN_API_KEY → FOUNTAIN_TOKEN → ~/.fountain/credentials
baseUrl: option → FOUNTAIN_BASE_URL → ~/.fountain/credentials → hosted
```

```ts
new Fountain({ apiKey: process.env.FOUNTAIN_API_KEY, baseUrl: "https://fountain.internal" });
new Fountain({ profile: "work" });   // a profile from ~/.fountain/credentials
```

`FOUNTAIN_TOKEN` is what a Fountain sandbox exports for the agent running
inside it. An agent that imports this SDK therefore delegates with the token it
already has, and the conversations it starts are recorded as its children — no
extra configuration to fan work out.

## Waiting, or not

`run()` starts the work and hands back a handle. What you do with the handle
decides how much of the run you see; there is no second request behind any of
these.

```ts
// await it — the finished answer
const result = await fountain.run(prompt, { agent: "reposage" });

// stream the words
const run = fountain.run(prompt, { agent: "reposage" });
for await (const chunk of run.textStream) process.stdout.write(chunk);
const result = await run;                      // same run, now finished

// or watch everything: tools, thinking, lifecycle
for await (const event of run) {
  if (event.type === "tool") console.log("→", event.name);
  if (event.type === "text") process.stdout.write(event.text);
}

// or don't wait at all — fan out, collect later
const runs = agents.map((agent) => fountain.run(prompt, { agent }));
const results = await Promise.all(runs);
```

A `RunResult` is:

```ts
{
  conversationId: string;   // keep it — the sandbox is still there
  url: string;              // where a human watches
  turnNumber: number;
  text: string;             // the answer, tool noise removed
  toolsUsed: string[];
  state: "done" | "failed" | "interrupted" | "timeout";
  exitCode: number | null;
  reason: string | null;    // stop_reason, or why it failed
  status: string | null;    // the conversation's status
}
```

A turn that **fails** is a result, not an exception — the agent ran and has
something to say about it. Check `state`. Only a transport failure, a rejected
request or a timeout throws.

## Defining what you run

`run()` names an agent; this is where the agent comes from. The whole
vocabulary fits on one screen:

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
  system: "You are a careful reader of other people's code.",
  environment_id: environment.id,
  skills: [
    { source: "obra/superpowers", ref: "v2.1.0" },
    { name: "house-style", content: "# House style\n\nPrefer small diffs." },
  ],
  mcp_servers: { linear: { command: "npx", args: ["-y", "linear-mcp"] } },
  allowed_vault_ids: [vault.id],   // this agent may attach that vault, and no other
});

await fountain.run("Find every N+1 query and open a PR", {
  agent: "reposage",
  vault: "github-bot",
});
```

`agents`, `environments` and `vaults` all have the same five verbs — `list`,
`get`, `create`, `update`, `delete` — and take a name or an id:

```ts
await fountain.agents.update("reposage", { model: "anthropic/claude-opus-5" });
await fountain.environments.secrets.set("fountain-ci", "HEX_API_KEY", "…");
await fountain.vaults.secrets.list("github-bot");   // keys only — never values
await fountain.vaults.secrets.delete("github-bot", "GITHUB_USER");
```

Secret values are write-only. `list` returns keys and nothing else: the SDK can
put a credential into a sandbox and cannot read it back out.

**Why `environment_id` and not `environmentId`.** Resource payloads use the
API's own key names, so one definition reads identically in the SDK, in the
REST API and in a `fountain.yml` manifest. Options that control the SDK's own
behaviour — `timeoutMs`, `signal` — are camelCase, because those are not data.

## The team

Ten of the eleven applications built on Fountain talk to `/api/team`, and some
never touch `/api/conversations` at all — a teammate is durable (one agent, one
long-running sandbox, one thread you keep messaging) where a conversation is
something you open and close.

```ts
await fountain.team.add("watchtower", { name: "Watchtower" });

const reply = await fountain.team.message("watchtower", "Any disks over 80%?");
console.log(reply.text);          // `message()` returns the same Run handle as `run()`

for await (const event of fountain.team.stream({ streams: ["stage"] })) {
  if (event.stage === "turn" && event.state === "done") refreshRoster();
}
```

`list`, `get`, `rename`, `remove`, `history`, `freshConversation`, and
`team.schedules.*` for cron routines. The stream reconnects from its last event
id on its own, and carries server-parsed `blocks` like every other feed — the
runtime is picked per event from the conversation that produced it — so one
connection is enough to render a thread.

Opening a thread is two calls, and every app wrote both by hand first:

```ts
const conversation = fountain.resume(id);
const events = await conversation.history({ streams: ["acp", "stage"] });  // paged to the end
await conversation.markRead();
```

## Errors

Branch on `code`, not status — `conversation_busy` is a 400,
`sandbox_quota_exceeded` a 429, `provisioning` a 503:

```ts
if (error instanceof ConversationBusyError) …   // the turn in flight must finish
if (error instanceof QuotaExceededError) …      // error.activeSandboxes / error.limit
if (error instanceof NotReadyError) …           // error.retryAfter, from the server
if (error instanceof ValidationError) …         // error.fieldErrors
```

Every error carries `status`, `code`, `body`, `retryAfter` and `retryable`.

## In a browser

The default entry imports no Node built-in, so it bundles as-is; the
credentials-file reader lives behind the `node` export condition.

```ts
const fountain = new Fountain({ baseUrl, apiKey });   // from your own settings UI
```

Your origin has to be in the server's `API_CORS_ORIGINS`, or every call fails
before it starts — `ConnectionError` says so, because "Failed to fetch" has
sent more than one person hunting through their own code.

## Generated underneath

`src/generated/openapi.ts` is produced from the same OpenAPI document the
server serves, and CI regenerates it and fails on a diff — so the types cannot
drift from the API. `import type { components, paths } from "fountain-sdk"` for
the raw shapes. What is hand-written is what a spec cannot express: that many
log events fold into one turn, and which of 85 paths are worth a verb.

## Follow-ups

```ts
const first = await fountain.run("Find every N+1 query in this repo", { agent: "reposage" });

const second = await fountain.resume(first.conversationId).send("Fix the worst three.");
```

The second turn costs one prompt. The sandbox is the same machine, the checkout
is where the first turn left it, and the agent's session still holds everything
it learned — this is the part a stateless API cannot do at any price.

## Timeouts and cancellation

By default `run()` waits as long as the turn takes; agent work legitimately
runs for hours.

```ts
try {
  await fountain.run(prompt, { agent: "reposage", timeoutMs: 5 * 60_000 });
} catch (error) {
  if (error instanceof TimeoutError) {
    // The turn did not stop — only the waiting did.
    console.log(error.partialText);
    const rest = await fountain.resume(error.conversationId).send("status?");
  }
}
```

- `timeoutMs` — stop waiting, throw `TimeoutError`. The agent keeps working.
- `signal` — an `AbortSignal` that stops the waiting, same deal.
- `run.interrupt()` — ask the agent to stop the turn. The sandbox stays up.
- `run.terminate()` — tear the sandbox down. Nothing resumes after this.

## Errors

Every failure is a `FountainError` with `status`, `code` and `body`:

| class | when |
|---|---|
| `AuthError` | 401, or no key configured at all |
| `SubscriptionRequiredError` | 402 — carries `upgradeUrl` |
| `NotFoundError` | 404 — wrong id, or it belongs to another account |
| `ValidationError` | 422 |
| `RateLimitError` | 429 |
| `TimeoutError` | the SDK stopped waiting — carries `conversationId` and `partialText` |
| `ResolutionError` | a name matched no agent/vault/environment, or matched several |

A `ResolutionError` names what the account actually has, so a typo is a
one-line fix rather than a trip to the console.

## The rest of the API

The verbs above are the ones worth wrapping. Everything else Fountain exposes —
61 paths and counting: audit, schedules, the team, API keys, conversation trees
and images — is one call away, with the same auth and error mapping:

```ts
await fountain.request("GET", "/api/audit", { query: { limit: 50 } });
await fountain.request("POST", "/api/vaults", { body: { name: "staging" } });
```

`GET /api/openapi.json` is the generated, always-current spec for those.

## Names, not ids

`agent`, `vault` and `environment` all take a name or an id. Names resolve
against the account (exact match first, then a unique prefix) and the listings
are memoized per client. A UUID in a script tells the next reader nothing;
`vault: "github-bot"` tells them everything.

## Development

```bash
npm install
npm test          # node --test, against an in-process fake Fountain
npm run typecheck
npm run build
```

The tests run a fake Fountain over real HTTP and real SSE, including the parts
that are easy to get wrong: a connection that dies mid-turn, output belonging
to another turn, and the two different ways runtimes chunk their text.

## License

MIT, same as Fountain.
