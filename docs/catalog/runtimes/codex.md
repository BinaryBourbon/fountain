# Run Codex as an API

> OpenAI's Codex CLI, headless in the sandbox.

Run Codex on a sandbox with your repositories, packages and credentials.
Send a prompt over HTTP, follow the transcript, and send the next prompt to
the same conversation. Fountain manages the machine between turns.

To use a chat interface, [open Conversations](https://fountain-conversations.demo.managoat.com/).
To call it from your own code, follow the [quickstart](../../quickstart.md),
then use the agent definition below.

## Summary

| | |
|---|---|
| Provider | `openai` |
| Multi-provider | No |
| Transport | ACP, through the pinned `codex-acp` adapter |
| Skills root | `/home/sprite/.codex/skills` |
| skills.sh agent | `codex` |
| System prompt | `~/.codex/AGENTS.md` |
| Credential | An OpenAI API key |

## Why you would choose this one

You want an OpenAI model to do the work. Or you compare two runtimes on the
same task.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: reviewer
spec:
  runtime: codex
  model: openai/gpt-5.3-codex
```

The model must carry the `openai/` prefix.

Add your OpenAI key at `/account/inference-credentials` in the app.

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

Run a conversation. A turn that reaches output proves the credential and the
adapter.

## Limits

The CLI takes the bare model id, so Fountain removes the `openai/` prefix
before it calls the CLI. You never see that in normal use. It matters when you
read a spawn command in the logs.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
