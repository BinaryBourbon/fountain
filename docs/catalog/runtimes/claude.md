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
| Credential | A Claude Code OAuth token, or an Anthropic API key. See [which one it uses](#which-credential-it-uses) |

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

Add your credential at `/account/inference-credentials` in the running app. An
operator cannot set one for you. See
[Services Fountain uses](../../integrations/index.md).

## Which credential it uses

Two kinds work, and if you have both on file **the OAuth token wins**.

| Credential | Bills |
|---|---|
| Claude Code OAuth token | Your Claude.ai subscription (Pro or Team) |
| Anthropic API key | Metered API usage |

That preference is the reason the order matters to you rather than to
Fountain. A subscription you are already paying for is usually the one you
want spent.

**Exactly one is exported into the sandbox, never both.** Claude Code prefers
the OAuth path when it sees both, but which variable it actually picks has
varied between CLI versions, so Fountain chooses one rather than letting the
CLI decide.

### When an organization disallows the subscription

An Anthropic organization can disable Claude subscription access for Claude
Code. When it has, a turn using the OAuth token fails with
`oauth_org_not_allowed`.

Fountain recovers rather than leaving you to work it out.

- **With an API key on file**, the conversation switches to it and the turn
  fails with a message saying so. Send the prompt again and it runs.
- **Without one**, the turn fails with a message telling you to add one.

Two details worth knowing about the recovery.

**The turn still fails.** The switch is not a silent retry, so the failure and
the fix are both in the transcript rather than only in a log nobody reads.

**The switch lasts for that conversation, not forever.** A new conversation
tries the OAuth token again, so an organization policy that is later reverted
heals on its own instead of staying pinned to the fallback.

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
