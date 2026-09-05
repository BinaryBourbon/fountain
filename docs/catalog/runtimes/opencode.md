# Run OpenCode as an API

> The opencode CLI. The only runtime that can reach more than one provider.

Run OpenCode on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Fountain manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `anthropic`, `openai` or `google` |
| Multi-provider | **Yes** |
| Transport | ACP, through opencode's own `acp` subcommand |
| Skills root | `/tmp/.config/opencode/skills` |
| skills.sh agent | `opencode` |
| System prompt | `~/.config/opencode/AGENTS.md` |
| Credential | Whichever provider the model prefix names |

## Why you would choose this one

It is the only runtime where a change of provider is a one-line edit to
`model`. On the others it is a different agent.

It takes the canonical `provider/model-id` string word for word. It then reads
the prefix to decide which API key to export into the sandbox.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: portable
spec:
  runtime: opencode
  model: anthropic/claude-sonnet-4-6   # or openai/... or google/...
```

Add a key for whichever provider you name, at
`/account/inference-credentials`.

## Call it over HTTP

After you apply the agent definition, set `FOUNTAIN_AGENT_ID` to the returned
agent id, `FOUNTAIN_BASE_URL` to your instance URL, and `FOUNTAIN_API_KEY` to
your Fountain account key. The account key is separate from the model credential.

```sh
--8<-- "docs/snippets/first-request.sh"
```

Use the returned conversation id to [follow events and send another prompt](../../api.md).
A self-hosted instance uses the same request at its own base URL.

## Verify

Run a conversation. Then change `model` to a different provider and run
another one. Two runs that both work are what this runtime is for.

## Limits

**Three providers, and no more.** `anthropic`, `openai` and `google` are the
only prefixes that Fountain can export a credential for. Fountain rejects a
fourth when you save the agent, so it does not fail later as an auth error in
the sandbox.

**A provider you hold no key for fails at the turn, and not at save time.**
Fountain validates the prefix. It does not check that your credential is
there.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
