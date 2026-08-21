# Operations

Running an instance day to day.

[Architecture](architecture.md) tells you which component owns a symptom. These
pages are the action level, meaning what to run and what the output means.
Commands are shown for both deploy paths where they differ.

## When something is wrong

Start from the symptom in [Troubleshooting](troubleshooting/index.md).

| You see | Read |
|---|---|
| A conversation sits in `running` with no output, or went `failed` | [A conversation is stuck or failed](troubleshooting/conversation-stuck-or-failed.md) |
| Provisioning fails while everything else is healthy | [Sandbox errors](troubleshooting/sandbox-errors.md) |
| Pods restart, or sit NotReady | [Pods restarting or not ready](troubleshooting/pods-restarting.md) |
| Registration completes but nobody gets past "check your email" | [Nobody can log in](troubleshooting/nobody-can-log-in.md) |

## Routine work

- [Run a release task](guides/operate/run-a-release-task.md), the invocation
  pattern every operator action uses, and the five tasks
- [Back up and restore](guides/operate/back-up-and-restore.md), including the
  restore drill
- [Upgrade an instance](guides/operate/upgrade.md), and what to do when one
  goes wrong
- [Wire up observability](guides/operate/observability.md), metrics, alerts,
  logs and the health endpoints

## Standing it up in the first place

See [Self-hosting](self-hosting.md).
