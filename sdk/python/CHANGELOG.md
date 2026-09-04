# Changelog

## 0.2.0

- Add `conversations.reapply`, which re-selects a conversation's agent,
  environment and vault without starting a new conversation. The id, title,
  turns and transcript are kept, and the next prompt runs on a fresh machine
  and a new runtime session. Pass nothing to refresh the current selection; an
  omitted field stays as it is, and an explicit `None` clears the environment
  override or the vault.

## 0.1.0

- First Python SDK release.
- Run and resume agents, stream turns, and answer permission requests.
- Manage agents, environments, vaults, teammates, schedules, and connections.
