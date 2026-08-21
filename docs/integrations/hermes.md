# Hermes Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is Nous Research's
self-hosted agent — a CLI, a TUI, and a gateway that fronts Telegram, Discord,
Slack and the rest — with a plugin system for adding tools. Fountain ships a
Hermes plugin that turns every Fountain agent on your account into something
Hermes can delegate to: Hermes calls `fountain_run`, Fountain provisions a
sandbox for that agent, the work runs there, and the answer comes back as the
tool result.

```
  Hermes (CLI / TUI / gateway)  ──HTTPS──▶  Fountain  ──▶  sandbox: the Fountain agent
    fountain_run(agent, prompt)              /api/*         (its environment, vault, runtime)
```

It is **delegation, not a model provider.** Hermes keeps its own model and its
own loop; a Fountain agent is a contractor it hands a task to and hears back
from. (Hermes's `copilot-acp` provider — an ACP agent used *as the LLM* — would
also accept `fountain acp`, but it opens a fresh session per model call, which
for Fountain means a sandbox per Hermes turn. The plugin is the intended path.)

Why reach for it:

- **The work runs off the Hermes host**, in a sandbox with the agent's own
  environment (packages, cloned repos, network policy) and secrets that never
  touch the machine Hermes runs on.
- **The unit is a Fountain agent** the user already named and configured; the
  Hermes model just picks one by name.
- **Conversations are multi-turn and durable.** Hermes gets a
  `conversation_id`, can follow up in the same sandbox, and the same
  conversation is open in the Fountain conversations app while it runs.
- **Fan-out is a loop of tool calls**, not orchestration code.

## Setup

1. Credentials. On the Hermes host either export a key —

    ```bash
    export FOUNTAIN_API_KEY=ftn_…                       # from Settings → API keys, or the CLI
    export FOUNTAIN_BASE_URL=https://fountain.example  # only for a self-hosted instance
    ```

    — or install the CLI and log in; the plugin reads `~/.fountain/credentials`
    exactly as the CLI does (`FOUNTAIN_PROFILE` selects a profile):

    ```bash
    brew install BinaryBourbon/tap/fountain
    fountain auth login
    ```

    Inside a Fountain sandbox nothing is needed: the plugin picks up the
    conversation-scoped `FOUNTAIN_TOKEN` and marks the conversations it starts
    as children of the one it is running in.

2. Install and enable the plugin:

    ```bash
    hermes plugins install BinaryBourbon/fountain/integrations/hermes/fountain --enable
    ```

    From a checkout of this repo, a symlink does the same:
    `ln -s "$PWD/integrations/hermes/fountain" ~/.hermes/plugins/fountain &&
    hermes plugins enable fountain`.

3. Check it:

    ```
    hermes plugins doctor ~/.hermes/plugins/fountain    # 7 tool(s) registered
    hermes                                              # then, in the session:
    /fountain whoami
    /fountain agents
    ```

    The tools are on for the CLI and TUI by default. If you have saved an
    explicit toolset list with `hermes tools`, tick **Fountain** there.

Optional settings live under `plugins.entries.fountain.settings` in Hermes's
`config.yaml` and win over the environment: `base_url`, `api_key`, `profile`,
and `default_timeout_seconds` (see Long turns).

## What Hermes gets

| Tool | Does |
|---|---|
| `fountain_agents` | list the account's agents (name, runtime, model) |
| `fountain_run` | start a conversation with an agent — a fresh sandbox — and wait for the answer; `vault` / `environment` pick per-run overrides; `wait: false` returns the id at once |
| `fountain_send` | a follow-up turn in the same conversation; the agent remembers the earlier turns and the sandbox keeps its files |
| `fountain_wait` | keep waiting on the current turn and collect what arrived since the last look |
| `fountain_status` | lifecycle status and turns, no waiting |
| `fountain_conversations` | the live conversations on the account |
| `fountain_terminate` | end a conversation and destroy its sandbox |

Every result carries the conversation's `url`, so the transcript is one click
away in the Fountain UI. The answer itself is the agent's text — Fountain
serves the log feed pre-parsed into blocks (`?blocks=true`, ADR 0014), so the
plugin never learns a runtime's dialect; a claude, codex, gemini or opencode
agent all come back the same way.

Two extras: a `fountain` skill (`skill_view("fountain:fountain")`) that tells the
Hermes model *when* to delegate and how to brief an agent, and a `/fountain`
slash command (`agents`, `run <agent> <prompt>`, `send`, `wait`, `status`,
`conversations`, `terminate`, `whoami`) for driving it by hand from any Hermes
surface.

## Long turns

A Fountain turn can run for many minutes; Hermes deadlines a tool call at 420 s
by default (`timeouts.tools.sequential_call`). The plugin never sits inside one
call for the life of a turn: `fountain_run`, `fountain_send` and `fountain_wait`
return after `timeout_seconds` (default 300, from `default_timeout_seconds`)
with `done: false` and the output so far, and the model calls `fountain_wait`
to continue — the cursor is remembered, so each call returns only new text.
The skill spells this out; a turn is finished when `done` is `true` and
`turn_state` says `done`, `failed` (with a `reason`) or `interrupted`.

Provisioning is inside the first wait: a cold sandbox is typically 20–90 s
before the agent's first token, depending on the sandbox provider and the
environment's setup script.

## Limits

- **No permission prompts.** A Fountain agent runs under the sandbox's own
  policy; there is nothing to approve from Hermes. (Forwarding permission
  requests to a client is #643 and lands for `fountain acp` clients first —
  this plugin polls the log feed and is unaffected either way.)
- **Text only, one direction.** The plugin returns the agent's text and the
  names of the tools it used; files it wrote stay in the sandbox (push them
  from the environment's repo, or ask the agent to print them). Images in
  prompts are not passed through.
- **Agents are chosen, not managed.** Creating or editing agents, environments
  and vaults is Fountain's console, the CLI or `fountain apply`; the plugin lists and
  runs what exists.

The plugin source and its tests are at
[`integrations/hermes/`](https://github.com/BinaryBourbon/fountain/tree/main/integrations/hermes)
in the Fountain repo.
