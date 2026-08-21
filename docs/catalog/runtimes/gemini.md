# gemini

> Google's Gemini CLI. The only runtime not on ACP.

## At a glance

| | |
|---|---|
| Provider | `google` |
| Multi-provider | No |
| Transport | **Legacy**, a line-delimited `stream-json` the worker tails |
| Skills root | `/tmp/.gemini/skills` |
| skills.sh agent | `gemini-cli` |
| System prompt | `~/.gemini/GEMINI.md` |
| Credential | A Gemini API key, exported as `GEMINI_API_KEY` |

## Why you would pick this one

You specifically want a Gemini model. That is the whole case.

If you do not, prefer [claude](claude.md), [codex](codex.md) or
[opencode](opencode.md), all of which are on ACP.

## Set it up

```yaml
apiVersion: fountain.dev/v1
kind: Agent
metadata:
  name: gemini-agent
spec:
  runtime: gemini
  model: google/gemini-2.5-pro
```

Add your Gemini key at `/account/inference-credentials`.

## Verify

Run a conversation. Output arriving at all proves the credential and the
legacy stream parser.

## Limits

**Not on ACP.** The other three runtimes speak the Agent Client Protocol, which
is what carries editor integration and the shared block format. Gemini uses the
older path, so it does not get those.

**Sessions are the CLI's, not Fountain's.** Gemini manages its own session
state, and `--resume` re-enters the most recent conversation in the workspace,
so Fountain does not pass a session id. One workspace holds one resumable
session.

## Related

- [About agents](../../concepts/agent.md)
- [Runtimes](index.md)
