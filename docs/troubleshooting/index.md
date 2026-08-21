# Troubleshooting

Start from the symptom you can see. Each page names the symptom, what causes
it, and what to run.

[Architecture](../architecture.md) tells you which component owns a symptom.
These pages are the action level, meaning what to run and what the output
means. Commands are shown for both deploy paths where they differ.

## By symptom

| You see | Read |
|---|---|
| A conversation sits in `running` with no output, or went `failed` | [A conversation is stuck or failed](conversation-stuck-or-failed.md) |
| Provisioning fails while everything else is healthy | [Sandbox errors](sandbox-errors.md) |
| Pods restart, or sit NotReady | [Pods restarting or not ready](pods-restarting.md) |
| Registration completes but nobody gets past "check your email" | [Nobody can log in](nobody-can-log-in.md) |
| Everyone is rate-limited at once | [Nobody can log in](nobody-can-log-in.md) |
| A rollout never completes | [Upgrade an instance](../guides/operate/upgrade.md) |
| A restore is needed | [Back up and restore](../guides/operate/back-up-and-restore.md) |

## Client-side problems

If the failure is in something driving Fountain rather than in Fountain, the
client's own page carries its failure modes.

- [`fountain acp`](../integrations/acp.md), the adapter editors and chat
  surfaces spawn.
- [Editors](../integrations/editors.md).
- [OpenClaw](../integrations/openclaw.md).
- [OpenBot](../integrations/openbot.md).
- [Buzz](../integrations/buzz.md).

## Setting up a workstation

Problems with a local development checkout are in
[Setup](../setup.md), not here.
