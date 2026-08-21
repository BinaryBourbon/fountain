# The shape everyone is cloning

The app on your timeline this month is the same app. A messaging client where
the contacts are bots: a roster down the left, a thread on the right, a **+**
that makes a new one with a name, a face and a one-line brief, and a settings
panel where you connect it to GitHub or Notion so it can actually do
something. Grok Bot shipped that shape, the clones are everywhere, and most of
them are good.

The front end is a weekend. What takes longer is the half nobody screenshots.

## What a bot needs that a chat UI does not give it

A bubble is text. A teammate is a process on a machine, and the machine is the
product:

| Behind the bubble | What it actually means |
|---|---|
| a computer | a filesystem, a shell, a package manager, a network |
| credentials | a GitHub token that works — not in the prompt, not in the transcript |
| memory | the second message costs a sentence, not a re-explanation of the first |
| isolation | one bot's token and files on a machine that is not the one serving your app |
| a lifecycle | something starts that machine, parks it while nobody is typing, wakes it |
| tenancy | the second person who signs in does not see the first one's bots |
| a clock | "every weekday at nine" |

None of that is chat. All of it is what separates a bot that answers from a
bot that does the thing.

## The two usual answers

**Run the agent on the user's own machine.** The app becomes a front end for a
process on your laptop: your Node, your keys in a dotfile, your working
directory. It is the fastest thing to build and it is genuinely lovely for one
person. It is also why the README starts with `git clone` — everybody who wants
a bot installs the whole stack, the bots stop when the lid closes, and "share
it with my team" has no answer.

**Take an endpoint.** Bring your own agent: a URL that speaks
[ACP](../integrations/acp.md), or an OpenAI-compatible chat completion, or a
framework's own protocol. Better — the app can now run anywhere — but it has
moved the hard part rather than solved it. Somebody still has to host that
runtime, give it a filesystem, put credentials in it, keep its memory between
calls, and stop one tenant reading another's. A chat-completions endpoint is
stateless and has no shell. An ACP endpoint has one only if you built it one.

Either way, the part that gets skipped is the part that costs money and pages
you at night.

## The third answer

Make the runtime an HTTP API that somebody else operates.

```
  A. the agent runs on the user's machine
     browser ──▶ local daemon ──▶ agent process ──▶ ~/.config, ~/code, your keys
                 one person, one laptop, asleep when the lid closes

  B. bring your own endpoint
     browser ──▶ your server ──▶ https://someones-agent/…
                 stateless: no shell, no files, nothing remembered
                 unless you also built and now operate that

  C. the runtime is an API                            ← this section
     browser ──▶ Fountain ──▶ a sandbox per teammate: shell, checkout,
     static files             secrets, memory that survives the message
```

Fountain is C. `POST /api/team` hires a teammate and gives it a computer;
`POST /api/team/:id/messages` says something to it; one SSE connection carries
what every teammate is doing. Your app is static files and a bearer token.

## What you write, and what you stop writing

| You write | Fountain does |
|---|---|
| the roster, the thread, the composer | provisions and holds a sandbox per teammate |
| what a bot is called, and what it looks like | starts `claude` / `codex` / `gemini` / `opencode` in it |
| which connectors you offer | encrypts the tokens, injects them at spawn, redacts them from output |
| your own sign-in, or none | accounts, API keys, OAuth, per-user isolation, quota, audit |
| what a routine is for | runs it on a cron |
| how a thread should look | parses each runtime's dialect into blocks you can render |

The second column is the one that has an on-call rotation.

## It already exists, twice

Two apps are built on this API and are open source. Neither has a
backend — both are static files talking to Fountain with a key the person
pasted in, or a "Sign in with Fountain" token.

- **[fountain-team](https://github.com/jhgaylor/fountain-team)** — the one this
  section walks through: roster, threads, queued messages while a teammate is
  busy, images, notifications, routines, ⌘K search, connectors, a live
  activity feed. A few thousand lines of React and no server of its own.
- **[fountain-conversations](https://github.com/jhgaylor/fountain-conversations)**
  — the same API from the other end: one conversation, in detail.

Fountain's own console does not do chat at all. It manages agents, secrets and
audit; the chat surfaces are these apps, on the public API, with no privileged
access. Whatever they do, your clone can do.

## Two things the clones do not have

**The teammates know each other.** Every conversation on the team channel is
handed an MCP server by Fountain itself, so a teammate can list the others,
find "the engineer", send them a message and wait for the reply — and the
exchange shows up in both threads. See [Team](../api.md#team).

**A teammate is not locked to your app.** The same agent answers over
[ACP](../integrations/acp.md) in an editor, over
[AG-UI](../integrations/openbot.md) from another agent platform, over
[Nostr](../integrations/buzz.md), and — where the instance enables it — from
its own email address and phone number. Each surface binds its own durable
thread through the same mechanism your app uses, so your UI is one door onto
something that exists whether or not the tab is open.

## Next

- [**A team chat, end to end**](team-chat.md) — the whole app in SDK calls:
  hire, message, stream, render, connect, schedule, ship.
- [**What each piece does**](pieces.md) — which primitive is doing what, and
  what happens between Enter and the first word of the reply.
