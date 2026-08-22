# gemini

> Google's Gemini CLI. The last runtime to reach ACP, and it reached it on
> 2026-08-22.

## At a glance

| | |
|---|---|
| Provider | `google` |
| Multi-provider | No |
| Transport | ACP, through the CLI's own `--acp` flag |
| Skills root | `/tmp/.gemini/skills` |
| skills.sh agent | `gemini-cli` |
| System prompt | `~/.gemini/GEMINI.md` |
| Credential | A Gemini API key, exported as `GEMINI_API_KEY` |

## Why you would choose this one

You want a Gemini model in particular. That is the whole case.

All four runtimes speak ACP, so the transport no longer decides this. Choose
[opencode](opencode.md) instead to move one agent definition between
providers.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: gemini-agent
spec:
  runtime: gemini
  model: google/gemini-3.1-pro-preview
```

Add your Gemini key at `/account/inference-credentials`.

## Verify

Run a conversation, then ask it what model it is. A turn that reaches output
at all proves the credential, the runtime and the sandbox.

## Limits

**Every turn after the first replays the whole transcript.** Gemini advertises
`loadSession` and no resume capability, so a turn loads the session again from
the start. Fountain discards that replay. The cost is time at the head of a
turn, and it grows with the transcript. The other three runtimes reattach.

**Fountain repairs gemini's session store after every turn.** The store
deletes a session while it loads it, an upstream defect
([gemini-cli#28775](https://github.com/google-gemini/gemini-cli/issues/28775)).
Fountain consolidates the store at the end of each turn, so a load cannot
collide with what it loads. That workaround goes away when upstream lands a
fix.

## Related

- [About agents](../../concepts/agent.md)
- [`fountain acp`](../../integrations/acp.md)
- [Runtimes](index.md)
