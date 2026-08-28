# Operations

This section is about how to run an instance day to day.

[Architecture](architecture.md) tells you which component owns a symptom.
These pages are the action level. They say what to run, and what the output
means. Where the two deploy paths differ, both commands appear.

## When something is wrong

Start from the symptom in [Troubleshoot a problem](troubleshooting/index.md).

| You see | Read |
|---|---|
| A conversation sits in `running` with no output, or it went `failed`. | [A conversation is stuck or failed](troubleshooting/conversation-stuck-or-failed.md) |
| A sandbox fails to start while the rest of the system is healthy. | [Sandbox errors](troubleshooting/sandbox-errors.md) |
| Pods restart, or they sit NotReady. | [Pods restart or never go ready](troubleshooting/pods-restarting.md) |
| Registration completes, but nobody gets past "check your email". | [Nobody can log in](troubleshooting/nobody-can-log-in.md) |

## Usual work

- [Run a release task](guides/operate/run-a-release-task.md), which is the
  pattern each operator action uses, and the five tasks
- [Back up and restore](guides/operate/back-up-and-restore.md), with the
  restore drill
- [Upgrade an instance](guides/operate/upgrade.md), and what to do when one
  goes wrong
- [Configure observability](guides/operate/observability.md), which covers
  metrics, alerts, logs and the health endpoints

## How to stand one up

Read [Self-host Fountain](self-hosting.md).
