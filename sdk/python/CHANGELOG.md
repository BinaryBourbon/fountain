# Changelog

## 0.2.0

- Add `Conversation.reapply()`, which re-selects a conversation's agent,
  environment and vault without starting a new conversation. The id, title,
  turns and transcript are kept, and the next prompt runs on a fresh machine
  and a new runtime session. Call it with no arguments to refresh the current
  selection; an omitted `agent_id`, `environment_id` or `vault_id` stays as it
  is, and `None` for either of the last two clears it.

## 0.1.0

- First Python SDK release.
- Run and resume agents, stream turns, and answer permission requests.
- Manage agents, environments, vaults, teammates, schedules, and connections.
