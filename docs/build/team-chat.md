# A team chat, end to end

Everything below is the [TypeScript SDK](../sdk.md) against a live instance,
in the order you would write it. It is the same sequence
[fountain-team](https://github.com/jhgaylor/fountain-team) performs — that app
predates the SDK and calls `fetch` directly, so its hand-written API client is
roughly what the SDK now wraps.

Nothing here needs a server of your own. The whole app is static files and a
bearer token.

## 1. A client

```ts
import { Fountain } from "fountain-sdk";

const fountain = new Fountain({
  baseUrl: "https://fountain.example.com",   // your instance
  apiKey,                                     // pasted once, or an OAuth token
});

const me = await fountain.me();               // the cheapest check that a key works
```

In Node the arguments are optional — credentials resolve from the environment
and `~/.fountain/credentials` exactly as the [CLI](../cli.md)'s do. In a
browser you pass what the person gave you, and the server has to allow your
origin (`API_CORS_ORIGINS`). See [shipping it](#10-shipping-it).

## 2. Hire a teammate

The **+** in these apps asks nothing. A name from a list, a sensible brain, a
one-line brief, and the roster has a new row a second later. That is two calls:
an [agent](../primitives.md#agent), and the agent put on the team.

```ts
const catalog = await fountain.catalog();          // this deployment's vocabulary
const model = catalog.models.claude?.[0] ?? "anthropic/claude-sonnet-5";

const agent = await fountain.agents.create({
  name: "watchtower",
  runtime: "claude",
  model,
  description: "Keeps an eye on the fleet",
  system: "You are Watchtower. You watch things and report only what changed.",
});

const teammate = await fountain.team.add(agent.name, { name: "Watchtower" });

teammate.conversation.id;      // the thread
teammate.presence.state;       // "starting" — a computer is being provisioned
```

`catalog()` is what stops the model dropdown going stale: the runtimes, the
suggested `provider/model` ids and the avatar vocabulary come from the server,
not from a list in your bundle.

Adding is idempotent, so the **+** does not need to know whether this agent is
already on the team. It is also the moment a machine appears: `team.add` opens
the teammate's standing conversation, and that provisions its sandbox.

!!! note "The face"

    If the account holds an OpenAI credential, Fountain will draw one:

    ```ts
    const image = await fountain.request<{ data: string; media_type: string }>(
      "POST",
      "/api/avatars/generate",
      { body: { base: catalog.avatar.bases[0], mood: catalog.avatar.moods[0] } },
    );
    await fountain.request("PUT", `/api/agents/${agent.id}/avatar`, { body: image });
    ```

    Reading it back needs the bearer key, so an `<img src>` straight at the
    URL will 401. Fetch the bytes and hand the element an object URL:

    ```ts
    const response = await fountain.api.raw("GET", `/api/agents/${agent.id}/avatar`);
    element.src = URL.createObjectURL(await response.blob());
    ```

## 3. The roster

```ts
const roster = await fountain.team.list();

for (const teammate of roster) {
  render({
    name: teammate.name,                       // its title, else the agent's name
    status: teammate.presence.label,           // "working", "asleep · wakes on message"…
    line: teammate.preview?.text ?? "",        // the last thing said, either way
    who: teammate.preview?.kind,               // "you" | "them" | "typing"
    bold: teammate.unread,
    tokens: teammate.usage_total,              // summed over every thread it has had
  });
}
```

One call fills a roster row completely — nothing here is assembled from three
endpoints and a guess. `presence.state` is the enum behind the label:
`working`, `starting`, `online`, `asleep`, `away`, `machine_offline`,
`failed`, `offline`. `asleep` is a teammate whose computer has been
[parked](../primitives.md#conversation) for want of anything to do; it wakes
on the next message with its memory intact, and your UI does not have to do
anything about it beyond saying so.

## 4. Say something

```ts
const run = fountain.team.message("watchtower", "Any disks over 80%?");

for await (const chunk of run.textStream) appendToBubble(chunk);

const result = await run;
if (result.state !== "done") markFailed(result.reason);   // failed, interrupted, timeout
```

`message()` hands back the same `Run` handle `fountain.run()` does. You can
await it for the finished reply, iterate `textStream` for the words as they
land, iterate the run itself for tool calls and thinking, or drop it entirely
and let the team stream in the next section carry the answer to whichever
component is showing that thread.

A turn that fails is a result, not an exception: check `state`. Only a
transport failure or a rejected request throws, which is what §7 is about.

## 5. One connection for the whole app

A chat app needs to know what everyone is doing, not just the thread that is
open. That is one endpoint, not one socket per teammate:

```ts
for await (const event of fountain.team.stream({ streams: ["stage"] })) {
  // A `team` or `schedule` notice: the roster or the routines changed.
  if (!event.agent_id) {
    void refreshRoster();
    continue;
  }

  if (event.stage === "turn") {
    if (event.state === "started") setTyping(event.agent_id, true);
    if (event.state === "done") {
      setTyping(event.agent_id, false);
      void reloadThread(event.conversation_id!);
      notifyIfNotLooking(event.agent_id);
    }
  }
}
```

Every payload is a conversation's log event plus `conversation_id` and
`agent_id`, so it routes to a roster row without a lookup. The iterator
reconnects from its own last event id, which means a Fountain deploy, a proxy
timeout or a laptop lid does not lose events — and your reconnect logic is the
`for await` you already wrote.

The stages worth knowing are the ones a UI shows while nothing is being said
yet — `provision`, `setup` and `reattach`, then `turn`, then `terminate` —
each with a `state` of `started`, `done`, `failed` or `interrupted`.

!!! note "The team stream carries raw events"

    `/api/team/stream` takes `streams` and nothing else — no `blocks` — so it
    is a notification channel: *something happened, to whom*. Read the
    transcript itself from the conversation's own feed, which does parse
    blocks. That is the next section.

## 6. Open a thread

Three calls. The third is the one that stops your app shouting about messages
the person is currently reading.

```ts
const conversation = fountain.resume(conversationId);

const [turns, events] = await Promise.all([
  conversation.turns(),                                  // the prompts, in order
  conversation.history({ streams: ["acp", "stdout"] }),   // paged to the end for you
]);

await conversation.markRead();
```

Each turn is a pair of bubbles: what was said, and everything the agent did
about it. Group the feed by `turn_id` and you have both:

```ts
import type { Block, LogEvent, Turn } from "fountain-sdk";

function bubbles(turns: Turn[], events: LogEvent[]) {
  const byTurn = new Map<string, Block[]>();
  for (const event of events) {
    if (!event.turn_id) continue;
    const blocks = byTurn.get(event.turn_id) ?? [];
    blocks.push(...(event.blocks ?? []));
    byTurn.set(event.turn_id, blocks);
  }

  return turns.flatMap((turn) => [
    { from: "you" as const, text: turn.prompt },
    { from: "them" as const, parts: fold(byTurn.get(turn.id) ?? []) },
  ]);
}
```

And a reply is a handful of blocks, folded the way a chat bubble wants them —
adjacent prose joined, a run of tool calls collapsed into one line you can
expand:

```ts
type Part = { kind: "text" | "thinking" | "tools"; body: string; tools: string[] };

function fold(blocks: Block[]): Part[] {
  const out: Part[] = [];
  for (const block of blocks) {
    const last = out.at(-1);
    if (block.kind === "text" || block.kind === "thinking") {
      if (last?.kind === block.kind) last.body += block.body ?? "";
      else out.push({ kind: block.kind, body: block.body ?? "", tools: [] });
    } else if (block.kind === "tool_use") {
      if (last?.kind === "tools") last.tools.push(block.name ?? "a tool");
      else out.push({ kind: "tools", body: "", tools: [block.name ?? "a tool"] });
    }
  }
  return out;
}
```

That is the entire transcript renderer, and the reason it fits on a screen is
`blocks`. The log feed holds whatever dialect the runtime speaks — ACP
`session/update` notifications for `claude`, `codex` and `opencode`, plain
stdout for others — and `?blocks=true`, which `history()` sets for you, parses
it server-side into `text`, `thinking`, `tool_use`, `tool_result`, `init`,
`result`, `error` and `raw`. fountain-team shipped a 200-line port of
Fountain's own ACP parser before this existed. Do not repeat that.

## 7. The things a messaging app is judged on

**Busy.** A teammate is one computer running one turn. A message sent
mid-turn is refused, and the right answer is not an error toast:

```ts
import { ConversationBusyError } from "fountain-sdk";

try {
  await fountain.team.message("watchtower", text);
} catch (error) {
  if (error instanceof ConversationBusyError) queue.push(text);   // send it at turn-end
  else throw error;
}
```

Queue locally, flush on the `turn`/`done` event from §5, and several queued
notes go as one turn. Branch on `error.code`, never on the status — see the
[error table](../sdk.md#errors).

**Stop.** Interrupt ends the turn and keeps the computer; terminate takes the
computer down.

```ts
const conversation = await fountain.team.conversation("watchtower");
await conversation.interrupt();
```

**Images.** Base64 in, on the same call:

```ts
await fountain.team.message("watchtower", "What is wrong with this graph?", {
  images: [{ data: base64, media_type: "image/png" }],
});
```

**Search.** Across every conversation the key can see, prompts and replies:

```ts
const hits = await fountain.search("disk usage");
// { conversation_id, agent_id, turn_id, turn_number, kind: "title"|"prompt"|"reply", snippet }
```

`turn_number` is what lets a ⌘K hit open the thread scrolled to the right
bubble.

**A clean slate.** A long thread eventually wants a fresh start without losing
the machine it was working on:

```ts
await fountain.team.freshConversation("watchtower");  // same computer, new session
const past = await fountain.team.history("watchtower"); // the retired threads
```

The old thread is retired and stays readable; the next message starts a new
runtime session on the same disk, so the agent's context is new but its
clones, installs and files are where it left them.

## 8. Give a teammate an app to use

This is the part the clones call connectors, and it is where a hosted runtime
stops being a convenience. A connector is an MCP server the teammate's runtime
talks to, and it usually needs a real credential.

The credential does not go in the agent config. It goes in the teammate's
[environment](../primitives.md#environment) as a secret, and the server
definition refers to it by name:

```ts
const environment = await fountain.environments.create({ name: "watchtower-env" });
await fountain.agents.update("watchtower", { environment_id: environment.id });

await fountain.environments.secrets.set(environment.name, "GITHUB_TOKEN", token);

await fountain.agents.update("watchtower", {
  mcp_servers: {
    github: {
      type: "http",
      url: "https://api.githubcopilot.com/mcp/",
      headers: { Authorization: "Bearer ${GITHUB_TOKEN}" },
    },
  },
});
```

`${GITHUB_TOKEN}` is resolved by [substitution](../primitives.md#substitution)
when the computer is set up. Three things follow, and they are the reason this
is not just a nicer way to store a string:

- The token is never in a prompt, a model's context, or the log feed your app
  reads.
- Fountain **redacts every environment value of 8 bytes or more out of the
  conversation's output**, on the single write path every log event takes. An
  agent asked to print its token persists `[REDACTED]`.
- Secret values are write-only. `secrets.list()` returns keys. Your app can
  give a teammate a credential and cannot read it back — which is exactly what
  you want to be able to tell someone pasting a GitHub token into a web page.

A connector applies when the computer is next set up, not to the machine
already running.

## 9. Routines

Cron, per teammate, server-side. Nothing in your app has to be awake.

```ts
await fountain.team.schedules.create("watchtower", {
  cron: "0 9 * * 1-5",                       // five fields, UTC
  prompt: "Check disk usage and say only what changed.",
  name: "Morning sweep",
});

const routines = await fountain.team.schedules.list();          // the whole team's
await fountain.team.schedules.run("watchtower", routines[0].id);  // "Run now"
```

By default the prompt lands in the teammate's own thread, as though you had
typed it, so the reply is in the conversation and in the agent's working
memory. `one_off: true` gives each run a fresh conversation on a new computer
instead, leaving the thread alone. The `schedule` notice on the team stream
tells your UI to re-list.

## 10. Shipping it

Static hosting. The only server-side facts are on the Fountain instance:

| What | Why |
|---|---|
| `API_CORS_ORIGINS` | a browser calling another origin's API is a CORS request; off by default, and it only ever admits a presented bearer key — cookies never cross origins |
| `OAUTH_CLIENTS` | to offer **Sign in with Fountain** instead of asking for a pasted key |

[Sign in with Fountain](../api.md#sign-in-with-fountain-oauth-20-for-browser-apps)
is OAuth 2.0 authorization code + PKCE, and the token it returns *is* an API
key: it lists and revokes under Account → API keys, and signing out revokes
it. That is the whole authentication story for an app with no backend.

## The whole thing, runnable

The roster row, the event router and the transcript folder above are one file
in this repo:
[`sdk/typescript/examples/chat.ts`](https://github.com/BinaryBourbon/fountain/blob/main/sdk/typescript/examples/chat.ts).
It hires a temporary teammate, prints the roster, sends a message, renders the
thread out of blocks and cleans up after itself:

```bash
cd sdk/typescript && npm install
FOUNTAIN_API_KEY=ftn_… node examples/chat.ts
```

CI typechecks it against the SDK on every push, which is the only reason this
page can promise the code on it compiles.
[`examples/team.ts`](https://github.com/BinaryBourbon/fountain/blob/main/sdk/typescript/examples/team.ts)
is the smaller version — hire, say two things, watch the stream.

## Where this goes next

- [**What each piece does**](pieces.md) — what happens between Enter and the
  first word, and which primitive is responsible for what.
- [**TypeScript SDK**](../sdk.md) — the full surface, including everything
  outside the team.
- [**API reference**](../api.md#team) — the routes underneath, for a language
  the SDK does not cover yet.
