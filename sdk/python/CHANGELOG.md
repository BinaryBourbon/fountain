# Changelog

## 0.2.0

- Add `Conversation.reapply()`, which applies a selection to the machine a
  conversation already runs on, so its files stay where the agent left them.
  Environment variables, the system prompt, skills and MCP configuration are
  rewritten, and the next prompt reads them. Call it with no arguments to
  refresh the current selection; an omitted `agent_id`, `environment_id` or
  `vault_id` stays as it is, and `None` for either of the last two clears it.
  A selection needing the disk rebuilt is refused with `409 rebuild_required`
  and a `field` naming what forced it.

## 0.1.0

- First Python SDK release.
- Run and resume agents, stream turns, and answer permission requests.
- Manage agents, environments, vaults, teammates, schedules, and connections.
