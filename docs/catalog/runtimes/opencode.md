# opencode

> The opencode CLI. The only runtime that can reach more than one provider.

## At a glance

| | |
|---|---|
| Provider | `anthropic`, `openai` or `google` |
| Multi-provider | **Yes** |
| Transport | ACP, through opencode's own `acp` subcommand |
| Skills root | `/tmp/.config/opencode/skills` |
| skills.sh agent | `opencode` |
| System prompt | `~/.config/opencode/AGENTS.md` |
| Credential | Whichever provider the model prefix names |

## Why you would pick this one

It is the only runtime where changing provider is a one-line edit to `model`
rather than a different agent.

It takes the canonical `provider/model-id` string verbatim and reads the prefix
to decide which API key to export into the sandbox.

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

## Verify

Run a conversation, then change `model` to a different provider and run
another. Both working is the thing this runtime is for.

## Limits

**The provider set is closed at three.** `anthropic`, `openai` and `google` are
the only prefixes Fountain can export a credential for, so a fourth is rejected
when you save the agent rather than failing as an auth error inside the
sandbox.

**A provider you have no key for fails at the turn, not at save time.** The
prefix is validated, the presence of your credential is not.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
