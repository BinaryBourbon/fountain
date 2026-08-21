# Overview

Fountain is a server. This section is everything that drives it from the
outside: an editor, a chat surface, a plugin host, a relay, your own code.

None of it is set up by the operator. There is no env var, no server-side
switch and nothing to run — each of these authenticates as an ordinary user,
with an API key or the CLI's saved login, and works against any instance it
can reach. If you are looking for the services Fountain itself needs
configured — sandboxes, mail, OAuth, billing, error tracking — those are in
[Services Fountain uses](index.md).

| Client | Talks over | Set up on |
|---|---|---|
| [Editors](editors.md) | [`fountain acp`](acp.md) | The developer's machine |
| [OpenClaw](openclaw.md) | [`fountain acp`](acp.md) | The OpenClaw host |
| [Hermes Agent](hermes.md) | HTTP API, via a plugin | The Hermes host |
| [OpenBot](openbot.md) | [AG-UI](https://github.com/ag-ui-protocol/ag-ui) over HTTP | The OpenBot host |
| [Buzz](buzz.md) | Nostr relay, hosted by Fountain | The Buzz desktop, or `POST /api/buzz/agents` |
| [Agentic IDEs](../llm-integration.md) | `/skill` + discovery endpoints | The IDE |
| Your own code | [HTTP API](../api.md), [TypeScript SDK](../sdk.md), [CLI](../cli.md) | Wherever you like |

## Over ACP

The first three of those spawn the same adapter. Its protocol surface, `_meta`
extensions and failure modes are on one page —
[**`fountain acp` (reference)**](acp.md) — so the client pages below only cover
setup.

[**Editors**](editors.md): an ACP-capable editor — Zed and friends — spawns
`fountain acp` locally and talks to your instance with the credentials the
developer already has.

[**OpenClaw**](openclaw.md) reaches the same adapter from a chat surface —
Telegram, Discord, Slack — by registering Fountain as a custom ACP agent in its
`acpx` plugin. The configuration is client-side, on the OpenClaw host.

## Over the API

[**Hermes Agent**](hermes.md) is a client of the HTTP API rather than of
`fountain acp`: a Hermes plugin (shipped in this repo under
`integrations/hermes/`) gives Hermes `fountain_run` and friends, so its model
delegates a task to a named Fountain agent and reads the answer back. The
plugin authenticates with an API key or the CLI's saved login.

[**OpenBot**](openbot.md) needs no plugin at all, only a URL: Fountain answers
[AG-UI](https://github.com/ag-ui-protocol/ag-ui) at `POST /api/agui/:agent_id`,
and CopilotKit's OpenBot — or any other AG-UI host — registers a Fountain agent
as a coworker with a channel of its own. One channel binds to one conversation,
so the sandbox is the memory rather than the replayed transcript. The coworker
holds an API key.

Everything that plugin does is available directly — see the
[API reference](../api.md), the [TypeScript SDK](../sdk.md) and the
[CLI reference](../cli.md). [LLM integration](../llm-integration.md) covers the
discovery endpoints that let an agentic IDE learn the whole surface from one
fetch.

## The other direction

[**Buzz**](buzz.md) inverts the arrangement: Fountain *hosts* a Buzz agent — a
Nostr identity that lives on a relay — running its coding agent in a sandbox
and holding its signing key in a vault. Nobody drives Fountain here; Fountain
shows up on the relay and answers. Provision one from the Buzz desktop or
`POST /api/buzz/agents`; it self-enables on any image that ships the
`buzz-acp` binary.
