# Overview

Fountain is a server. This section covers everything that drives it from the
outside. That is an editor, a chat surface, a plugin host, a relay, or your
own code.

The operator configures none of it. There is no env var, no server-side
switch, and nothing to run.

Each of these authenticates as an ordinary user, with an API key or with the
CLI's saved login. Each works against any instance it can reach.

If you want the services that Fountain itself needs, which are sandboxes,
mail, OAuth, billing and error reports, read <!-- vale disable-line STE.IngForms -->
[Services Fountain uses](index.md).

| Client | Talks over | Configured on |
|---|---|---|
| [Editors](editors.md) | [`fountain acp`](acp.md) | The developer's machine. |
| [OpenClaw](openclaw.md) | [`fountain acp`](acp.md) | The OpenClaw host. |
| [Hermes Agent](hermes.md) | The HTTP API, through a plugin. | The Hermes host. |
| [OpenBot](openbot.md) | [AG-UI](https://github.com/ag-ui-protocol/ag-ui) over HTTP. | The OpenBot host. |
| [OpenAI-compatible API](openai-compatible.md) (alpha) | OpenAI chat completions over HTTP. | The client or the gateway. |
| [Buzz](buzz.md) | A Nostr relay, hosted by Fountain. | The Buzz desktop, or `POST /api/buzz/agents`. |
| [Agentic IDEs](../llm-integration.md) | `/skill` and the discovery endpoints. | The IDE. |
| Your own code | The [HTTP API](../api.md), the [TypeScript SDK](../sdk.md), the [CLI](../cli.md). | Wherever you want. |

## Over ACP

The first three of those spawn the same adapter. One page holds its protocol
surface, its `_meta` extensions and its failure modes,
[**`fountain acp` (reference)**](acp.md). So the client pages below cover the
setup alone.

[**Editors**](editors.md). An ACP-capable editor, such as Zed, spawns
`fountain acp` locally. It then talks to your instance with the credentials
the developer already has.

[**OpenClaw**](openclaw.md) reaches the same adapter from a chat surface, such
as Telegram, Discord or Slack. Register Fountain as a custom ACP agent in its
`acpx` plugin. That configuration is client-side, on the OpenClaw host.

## Over the API

[**Hermes Agent**](hermes.md) is a client of the HTTP API, and not of
`fountain acp`. A Hermes plugin, which this repo ships under
`integrations/hermes/`, gives Hermes `fountain_run` and its siblings. Its
model then delegates a task to a named Fountain agent and reads the answer
back. The plugin authenticates with an API key, or with the CLI's saved login.

[**OpenBot**](openbot.md) needs no plugin at all, and only a URL. Fountain
answers [AG-UI](https://github.com/ag-ui-protocol/ag-ui) at
`POST /api/agui/:agent_id`. CopilotKit's OpenBot, or any other AG-UI host,
registers a Fountain agent as a coworker with a channel of its own. One
channel binds to one conversation, so the sandbox is the memory, and not a
transcript that somebody replays. The coworker holds an API key.

[**Any OpenAI-compatible client or gateway**](openai-compatible.md) needs
only a base URL too. This one is alpha, behind the `openai_compat` flag. Fountain answers `POST /v1/chat/completions` and
`GET /v1/models`, where the model is one of your agents. Open WebUI,
LibreChat, LiteLLM and the `openai` SDK all speak that shape. A header, or the
request's `user` field, binds each chat to one conversation, so the sandbox is
the memory here as well.

Everything that plugin does is available to you directly. Read the
[API reference](../api.md), the [TypeScript SDK](../sdk.md) and the
[CLI reference](../cli.md).

Do you build a chat surface of your own, the roster-and-threads app that
everybody clones? [**Build a chat app**](../build/index.md) walks the whole
thing through in SDK calls. [LLM integration](../llm-integration.md) covers
the discovery endpoints, which let an agentic IDE learn the whole surface from
one fetch.

## The other direction

[**Buzz**](buzz.md) inverts the arrangement. Fountain *hosts* a Buzz agent,
which is a Nostr identity that lives on a relay. Its coding agent runs in a
sandbox, and a vault holds its Nostr key. Nobody drives Fountain here.
Fountain arrives on the relay and answers.

Provision one from the Buzz desktop, or with `POST /api/buzz/agents`. It turns
itself on for any image that ships the `buzz-acp` binary.
