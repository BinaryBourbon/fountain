# The console, the apps, and the API

This page explains why Fountain's own UI does not show you an agent at work,
and where that happens instead. To connect your own client, read
[Plug into Fountain](../integrations/clients.md).

## Three surfaces, on purpose

| Surface | What it is | Where it runs |
|---|---|---|
| The console | Fountain's own browser UI. | The Fountain server. |
| The apps | Conversations and Team. | Their own origins, on `/api`. |
| The API | REST and SSE, with the CLI and the SDK over it. | Anywhere. |

## The console is an operator console

Fountain's own UI covers the dashboard, agents, environments, vaults, audit,
API keys, account and admin.

It is deliberately not an interactive application. You configure things in it.
You do not watch an agent work in it.

## To watch an agent work, use a different application

Two single-page apps sit on `/api`. Each one has its own origin and its own
OAuth client.

| App | What it does |
|---|---|
| [Conversations](https://github.com/jhgaylor/fountain-conversations) | Start a run, watch it, steer it, read the raw log. |
| [Team](https://github.com/jhgaylor/fountain-team) | Agents as teammates, one thread for each. |

They replaced in-app LiveViews. Six paths now redirect, and they do not 404.
They are `/conversations`, `/conversations/new`, `/conversations/:id`,
`/conversations/:id/logs`, `/team` and `/team/:agent_id`.

Links to them sit in sent emails, in filed support issues, in agents' skills
and in people's bookmarks.

`/onboarding` goes to the dashboard, whose checklist replaced the wizard.

The redirect is a 302 and not a 301, and that is deliberate. A browser caches a
permanent redirect past any later change of mind.

## Why divide them

**A conversation UI is a real-time application, and a console is not.** A form
that writes a row is one engineering problem. To stream a turn, to render a
tool call, to steer a run mid-turn and to interrupt it is a different one. Put
both in one LiveView, and each change to one risks the other.

**The apps are static builds with no server.** You type your Fountain's URL
in. So one hosted build works against each deployment, yours as well, as soon
as the server admits the origin.

```
API_CORS_ORIGINS=https://jakegaylor.com
```

**It forces the API to be complete.** Make `/api` the only way to watch a
conversation, and `/api` then holds everything a client needs. Anybody who
builds their own client stands level with the first-party one. `?blocks=true`
on the event streams exists for exactly this reason. The server parses the
runtime dialect, so no client writes that code again.

That last point is the real argument. A console that could do what the API
could not would quietly make the API second-class.

## What this means for you

**Do you build a feature that a conversation shows?** It goes in the app, and
not in Fountain. The server's job is to serve it.

**Do you self-host?** The hosted apps work against your instance once you set
`API_CORS_ORIGINS`. To host your own build instead, point
`CONVERSATIONS_APP_URL` and `TEAM_APP_URL` at it. Set either one to an empty
string to tell the console that this deployment has no such app. The console
then stops the offer. Read
[Deploy an instance](../guides/operate/deploy.md).

**Do you write something that links a person to a transcript?** Read the URL
from the one place that knows it. The console's links, an email's "open it", a
forwarded support report and `/api/catalog` all agree, because they all ask
the same module.

## What this is not

**Not a microservice split.** There is one server and one database. The apps
are static files with no backend of their own.

**Not a plugin system.** The apps are ordinary API clients with no special
access. Yours would have the same.

**Not permanent for the console.** The console keeps whatever a person needs
that is not a conversation. That boundary can move, and the redirects exist so
that it can move and break no link.

## Where to go next

- [Plug into Fountain](../integrations/clients.md), for editors, chat
  surfaces, plugins and SDKs.
- [Build a chat app](../build/index.md), the case for the API below it.
- [API reference](../api.md).
- [Agents as teammates](teammates.md), which is what the Team app renders.
