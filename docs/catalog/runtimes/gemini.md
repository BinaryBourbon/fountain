# gemini

> Google's Gemini CLI. The only runtime off ACP.

## At a glance

| | |
|---|---|
| Provider | `google` |
| Multi-provider | No |
| Transport | **Legacy**. A line-delimited `stream-json` that the worker tails. |
| Skills root | `/tmp/.gemini/skills` |
| skills.sh agent | `gemini-cli` |
| System prompt | `~/.gemini/GEMINI.md` |
| Credential | A Gemini API key, exported as `GEMINI_API_KEY` |

## Why you would choose this one

You want a Gemini model in particular. That is the whole case.

If you do not, choose [claude](claude.md), [codex](codex.md) or
[opencode](opencode.md). All three are on ACP.

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

Run a conversation. Output that arrives at all proves the credential and the
legacy stream parser.

## Limits

**Off ACP.** The other three runtimes speak the Agent Client Protocol, which
carries editor integration and the shared block format. Gemini uses the older
path, so it gets neither.

**The sessions belong to the CLI, and not to Fountain.** Gemini manages its
own session state. Its `--resume` re-enters the most recent conversation in
the workspace, so Fountain passes no session id. One workspace holds one
session that you can resume.

## Related

- [About agents](../../concepts/agent.md)
- [Runtimes](index.md)
