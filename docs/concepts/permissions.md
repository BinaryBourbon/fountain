# Before a tool runs

An agent works in a sandbox. Sooner or later it wants to run a command, edit a
file, or fetch a URL. A **permission policy** says what happens at that moment.

The runtime asks Fountain first. Fountain answers from the policy. The tool
then runs, or it does not.

## The three answers

| Verdict | What Fountain does |
|---|---|
| `auto_allow` | It permits the tool. This is the default, and it is what every agent did before the policy existed. |
| `ask` | It holds the request, and a human answers it. Nobody answers in 5 minutes, and Fountain refuses. |
| `auto_deny` | It refuses the tool. It chooses a refusal that the runtime offered, and invents none. |

A refusal does not stop the turn. The agent reads that it has no permission,
and it continues.

## Where a policy lives

An agent holds one. Each conversation on that agent runs under it.

A launch can send its own policy, on `POST /api/conversations`, on ACP
`session/new`, or with `fountain acp --permission`. Fountain merges the two,
and keeps the stricter verdict for each key.

**A launch can only narrow.** A launch policy that permits more than the agent
does gets a 422 that names the key. Fountain refuses it, and does not clamp it
quietly. Because of that rule, there is no allowlist beside this field. A
launch cannot reach a permission that the agent does not hold.

## Keys

A policy is a map. Each key names what the tool call is, and each value is a
verdict. The key `default` covers everything else.

```json
{ "default": "auto_allow", "execute": "ask" }
```

Fountain reads the keys in this order.

1. The **title** on the tool card, which is the agent's own words.
2. The **kind**, which is ACP's own short list. It is one of `read`, `edit`,
   `delete`, `move`, `search`, `execute`, `think`, `fetch`, `switch_mode` and
   `other`.
3. The key `default`.

**Prefer a kind.** The claude and gemini runtimes put the command itself in the
title, and codex sends no title. A title key therefore matches one command, and
nothing else. A kind means the same thing on each turn, and on each runtime.

## When a human answers

With `ask`, the agent stops and waits. Fountain puts the request on the
conversation stream, as a `permission_request` block. It carries the tool, a
summary, and the runtime's own options.

Anyone with the conversation can answer it. The team app and the conversations
app show a card. An editor over `fountain acp` shows its own approval prompt.
Your own code can answer with
`POST /api/conversations/{id}/requests/{request_id}`.

Some rules keep that safe.

- **The first answer wins.** The other clients see a request that no longer
  waits. No client is a fallback for another.
- **Nobody is also an answer.** After 5 minutes, Fountain refuses the tool. The
  timeout sits below the idle bound, so a request that waits costs a turn and
  not the sandbox.
- **An option must come from the runtime.** Fountain refuses an option id that
  the runtime did not offer.
- **The agent cannot answer itself.** The sandbox holds an API token, and
  Fountain refuses that loop by name.

## What each runtime can do

| Runtime | Asks before a tool | Notes |
|---|---|---|
| claude | Yes | Measured on claude-agent-acp 0.66. Safe commands that its own sandbox runs never reach Fountain. |
| codex | Yes | Measured on codex-acp 1.1.14. |
| opencode | **No** | It decides this in its own server, and sends nothing. Fountain refuses a policy stricter than `auto_allow` on this runtime, with 422 `permission_policy_unenforceable` ([#959](https://github.com/BinaryBourbon/fountain/issues/959)). |
| gemini | Yes | Measured on gemini 0.53 with `gemini-2.5-flash`. Google removed that model for new API keys after this measurement. Its option ids are its own (`proceed_once`, `cancel`), so answer with an id from the request, never a name you know from another runtime. |

## What the audit trail keeps

Fountain records a refusal, with the tool and the verdict. It records no
values, and no inputs.

It records no permits. One turn makes many tool calls, and a row for each would
make the trail a copy of the transcript.

## How to set one

- **The console.** Open the agent, and use *Before the agent runs a tool*.
- **The API.** `PATCH /api/agents/{id}` with `permission_policy`.
- **An editor.** `fountain acp --permission ask`, or
  `fountain acp --permission execute=ask`.
