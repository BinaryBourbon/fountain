# codex

> OpenAI's Codex CLI, running headless inside the sandbox.

## At a glance

| | |
|---|---|
| Provider | `openai` |
| Multi-provider | No |
| Transport | ACP, through the pinned `codex-acp` adapter |
| Skills root | `/home/sprite/.codex/skills` |
| skills.sh agent | `codex` |
| System prompt | `~/.codex/AGENTS.md` |
| Credential | An OpenAI API key |

## Why you would pick this one

You want an OpenAI model doing the work, or you are comparing two runtimes on
the same task.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: reviewer
spec:
  runtime: codex
  model: openai/gpt-5-codex
```

The model must carry the `openai/` prefix.

Add your OpenAI key at `/account/inference-credentials` in the running app.

## Verify

Run a conversation. A turn that reaches output proves the credential and the
adapter.

## Limits

The CLI takes the bare model id, so Fountain strips the `openai/` prefix before
invoking it. That is invisible in normal use and worth knowing if you are
reading a spawn command in the logs.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
