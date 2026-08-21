# The console, the apps, and the API

This page explains why Fountain's own UI does not show you an agent working,
and where that happens instead. For connecting your own client, see
[Plugging into Fountain](../integrations/clients.md).

## Three surfaces, on purpose

| Surface | What it is | Where it runs |
|---|---|---|
| The console | Fountain's own browser UI | The Fountain server |
| The apps | Conversations and Team | Their own origins, on `/api` |
| The API | REST, SSE, plus the CLI and SDK over it | Anywhere |

## The console is an operator console

Fountain's own UI covers the dashboard, agents, environments, vaults, audit,
API keys, account and admin.

It is deliberately not an interactive application. You configure things in it.
You do not watch an agent work in it.

## Watching an agent work is a different application

Two single-page apps sit on `/api`, each on its own origin with its own OAuth
client.

| App | What it does |
|---|---|
| [Conversations](https://github.com/jhgaylor/fountain-conversations) | start a run, watch it, steer it, read the raw log |
| [Team](https://github.com/jhgaylor/fountain-team) | agents as teammates, one thread each |

They replaced in-app LiveViews. `/conversations`, `/conversations/new`,
`/conversations/:id`, `/conversations/:id/logs`, `/team` and `/team/:agent_id`
now redirect rather than 404, because links to them are in sent emails, in
filed support issues, in agents' skills and in people's bookmarks. `/onboarding`
goes to the dashboard, whose checklist replaced the wizard.

The redirect is a 302 rather than a 301, deliberately. A permanent redirect
would be cached in browsers past any future change of mind.

## Why split them

**A conversation UI is a real-time application and a console is not.** Turn
streaming, tool-call rendering, steering a run mid-turn and interrupting it are
a different engineering problem from a form that writes a row. Putting both in
one LiveView meant every change to either risked the other.

**The apps are static builds with no server.** You type your Fountain's URL in.
That means one hosted build works against every deployment, including yours,
as soon as the server admits the origin.

```
API_CORS_ORIGINS=https://jakegaylor.com
```

**It forces the API to be complete.** If the only way to watch a conversation
is over `/api`, then `/api` has everything a client needs, and anyone building
their own client is on equal footing with the first-party one. `?blocks=true`
on the event streams exists for exactly this reason. The server does the
runtime-dialect parsing so no client re-implements it.

That last point is the real argument. A console that could do things the API
could not would quietly make the API second-class.

## What this means for you

**Building a conversation-facing feature?** It goes in the app, not in
Fountain. The server's job is to serve it.

**Self-hosting?** The hosted apps work against your instance once you set
`API_CORS_ORIGINS`. If you would rather host your own build, point
`CONVERSATIONS_APP_URL` and `TEAM_APP_URL` at it. Setting either to an empty
string tells the console this deployment has no such app, and it stops
offering it. See [Deploy an instance](../guides/operate/deploy.md).

**Writing something that links a human to a transcript?** Read the URL from
the one place that knows it. The console's links, an email's "open it", a
forwarded support report and `/api/catalog` all agree because they all ask the
same module.

## What this is not

**Not a microservice split.** There is one server and one database. The apps
are static files with no backend of their own.

**Not a plugin system.** The apps are ordinary API clients with no special
access. Yours would have the same.

**Not permanent for the console.** The console keeps whatever a human needs
that is not a conversation. That boundary can move, and the redirects exist so
it can move without breaking links.

## Where to go next

- [Plugging into Fountain](../integrations/clients.md), for editors, chat
  surfaces, plugins and SDKs.
- [Build a chat app](../build/index.md), the case for the API underneath.
- [API reference](../api.md).
- [Agents as teammates](teammates.md), which is what the Team app renders.
