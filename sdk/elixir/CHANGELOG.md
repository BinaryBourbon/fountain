# Changelog

## [0.2.0] - 2026-09-04

- Add `Fountain.Conversation.reapply/2`, which applies a selection to the
  machine a conversation already runs on, so its files stay where the agent
  left them. Environment variables, the system prompt, skills and MCP
  configuration are rewritten, and the next prompt reads them. Pass no options
  to refresh the current selection; an omitted key stays as it is, and `nil`
  under `:agent_id`, `:environment_id` or `:vault_id` is sent through as an
  explicit null. A selection needing the disk rebuilt is refused with
  `409 rebuild_required` and a `field` naming what forced it.

## [0.1.0] - 2026-09-02

- Initial Elixir SDK release.
- Add immediate agent runs with broadcast event and text streams.
- Add reconnecting, cursor-aware SSE with automatic `Last-Event-ID` resume.
- Add resumable follow-ups, permissions, conversation history, and turn control.
- Add agents, environments, vaults, write-only secrets, teammates, schedules, connections, and connection providers.
- Add sandbox lifecycle, file listing/read, and repository diff operations.
- Add CLI-compatible configuration, verified TLS, structured errors, and raw request access.
