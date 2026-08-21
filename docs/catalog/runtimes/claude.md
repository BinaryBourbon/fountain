# claude

> Anthropic's Claude Code CLI, running headless inside the sandbox.

## At a glance

| | |
|---|---|
| Provider | `anthropic` |
| Multi-provider | No |
| Transport | ACP, through the pinned `claude-agent-acp` adapter |
| Skills root | `/home/sprite/.claude/skills` |
| skills.sh agent | `claude-code` |
| System prompt | `~/.claude/CLAUDE.md` |
| Credential | An Anthropic API key or a Claude Code OAuth token |

## Why you would pick this one

It is the default and the most exercised path. Editor integration, the
permission flow and the block format all developed against it first.

Pick [opencode](opencode.md) instead if you want one agent definition that can
switch providers.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: researcher
spec:
  runtime: claude
  model: anthropic/claude-sonnet-4-6
```

The model must carry the `anthropic/` prefix. Anything else is rejected when
you save the agent.

Add your Anthropic key at `/account/inference-credentials` in the running app.
An operator cannot set one for you. See
[Services Fountain uses](../../integrations/index.md).

## Verify

Run a conversation and ask it what model it is. A turn that reaches output at
all proves the credential, the runtime and the sandbox.

## Limits

**MCP servers are provisioned rather than passed per session.** Session-scoped
MCP delivery is broken upstream in `claude-agent-acp`, so Fountain writes
`.mcp.json` into the sandbox and enables project servers instead. The effect is
the same and the mechanism is different, which matters if you are debugging why
a raw ACP probe behaves differently from Fountain.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
