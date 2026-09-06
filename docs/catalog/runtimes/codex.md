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

Check the turn's `model_selection` in `GET /api/conversations/:id/turns`.
The same fields appear in the `model` stream stage:

- `requested_model`: the ID sent to the runtime.
- `effective_model`: the runtime's selected ID, or `null` on selection failure.
- `source`: `runtime` for a returned model field, or `selection_ack` when the
  runtime accepted the setter without returning a model field.
- `status` and `error`: whether selection succeeded and the failure message.

Selection evidence is separate from the agent's saved model. To verify actual
execution, inspect Codex's session JSONL `turn_context.payload.model`. An
assistant's answer about its model is not execution evidence.

An explicit model that the runtime rejects stops the turn before inference.
Fountain does not substitute another model. An unavailable ID in the runtime
catalog does not, by itself, prove that your provider account lacks access.
Check the bundled Codex version, its refreshed `model/list` response, and the
provider response with the same credentials.

Fountain checks the pinned adapter version before opening a new connection,
including on a persistent sandbox. An existing connection keeps its process
until it closes. If an old runtime rejects the model, the failed connection
closes; retrying opens the updated adapter against the same session and disk.
The sandbox must allow registry access through its configured network path.

A saved agent model change takes effect on the next user turn, including on
an existing ACP connection. The conversation, session, transcript and worktree
remain in place. A change during a running turn applies to the next turn.

## Limits

The CLI takes the bare model id, so Fountain removes the `openai/` prefix
before it calls the CLI. You never see that in normal use. It matters when you
read a spawn command in the logs.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
