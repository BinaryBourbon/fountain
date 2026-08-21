# The shape everyone is cloning

The same app keeps turning up: a messaging client whose contacts are bots.
Roster on the left, thread on the right, a **+** that makes a new bot out of a
name and a one-line brief, and a settings panel for connecting it to GitHub or
Notion. Grok Bot shipped that shape and the clones are everywhere.

The front end is a weekend of work. The machinery under it is not.

## What a bot needs that a chat UI does not give it

A useful teammate is a process running on a machine, so something has to
supply the machine:

| Behind the bubble | What it actually means |
|---|---|
| a computer | a filesystem, a shell, a package manager, a network |
| credentials | a GitHub token that works, not in the prompt and not in the transcript |
| memory | the second message costs a sentence, not a re-explanation of the first |
| isolation | one bot's token and files on a machine that is not the one serving your app |
| a lifecycle | something starts that machine, parks it while nobody is typing, wakes it |
| tenancy | the second person who signs in does not see the first one's bots |
| a clock | "every weekday at nine" |

## The two usual answers

**Run the agent on the user's own machine.** The app becomes a front end for a
process on your laptop: your Node, your keys in a dotfile, your working
directory. Nothing is quicker to build, and for one person it works well. The
cost shows up in the README, which starts with `git clone`: everyone who wants
a bot installs the whole stack, the bots stop when the lid closes, and sharing
them with a team has no answer.

**Take an endpoint.** Bring your own agent: a URL speaking
[ACP](../integrations/acp.md), or an OpenAI-compatible chat completion, or a
framework's own protocol. The app can run anywhere now, but the hard part has
moved rather than gone. Somebody still hosts that runtime, gives it a
filesystem, puts credentials in it, keeps its memory between calls and stops
one tenant reading another's. A chat-completions endpoint is stateless and has
no shell. An ACP endpoint has one only if you built it one.

Both leave the same gap.

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

Fountain is that third shape. `POST /api/team` hires a teammate and gives it a
computer, `POST /api/team/:id/messages` says something to it, and one SSE
connection carries what every teammate is doing. Your app is static files and
a bearer token.

## What you write, and what you stop writing

| You write | Fountain does |
|---|---|
| the roster, the thread, the composer | provisions and holds a sandbox per teammate |
| what a bot is called, and what it looks like | starts `claude` / `codex` / `gemini` / `opencode` in it |
| which connectors you offer | encrypts the tokens, injects them at spawn, redacts them from output |
| your own sign-in, or none | accounts, API keys, OAuth, per-user isolation, quota, audit |
| what a routine is for | runs it on a cron |
| how a thread should look | parses each runtime's dialect into blocks you can render |

Only one of those columns has an on-call rotation.

## It already exists, twice

Two apps are built on this API, both open source and both without a backend
of their own: static files talking to Fountain with a key the person pasted
in, or a "Sign in with Fountain" token.

- **[fountain-team](https://github.com/jhgaylor/fountain-team)** is the one
  this section walks through: roster, threads, queued messages while a
  teammate is busy, images, notifications, routines, ⌘K search, connectors, a
  live activity feed. A few thousand lines of React.
- **[fountain-conversations](https://github.com/jhgaylor/fountain-conversations)**
  takes the same API from the other end, showing one conversation in detail.

Fountain's own console has no chat in it. It manages agents, secrets and
audit. The chat surfaces are these two apps, running on the public API with no
privileged access to it.

## Two things the clones do not have

**The teammates know each other.** Fountain hands every conversation on the
team channel an MCP server, so a teammate can list the others, find "the
engineer", send one of them a message and wait for the reply. The exchange
shows up in both threads. See [Team](../api.md#team).

**A teammate is not locked to your app.** The same agent answers over
[ACP](../integrations/acp.md) in an editor, over
[AG-UI](../integrations/openbot.md) from another agent platform, over
[Nostr](../integrations/buzz.md), and, where the instance enables it, from its
own email address and phone number. Each of those surfaces binds its own
durable thread through the mechanism your app uses. Your UI is one door onto
something that exists whether or not the tab is open.

## Next

- [**A team chat, end to end**](team-chat.md) walks the whole app through in
  SDK calls: hire, message, stream, render, connect, schedule, ship.
- [**What each piece does**](pieces.md) covers which primitive is responsible
  for what, and what happens between Enter and the first word of the reply.
