# Changelog

## [0.2.0] - 2026-09-04

- Add `Fountain.Conversation.reapply/3`, which re-selects a conversation's
  agent, environment and vault without starting a new conversation. The id,
  title, turns and transcript are kept, and the next prompt runs on a fresh
  machine and a new runtime session. Pass an empty map to refresh the current
  selection; an omitted key stays as it is, and an explicit `nil` clears the
  environment override or the vault.

## [0.1.0] - 2026-09-02

- Initial Elixir SDK release.
- Add immediate agent runs with broadcast event and text streams.
- Add reconnecting, cursor-aware SSE with automatic `Last-Event-ID` resume.
- Add resumable follow-ups, permissions, conversation history, and turn control.
- Add agents, environments, vaults, write-only secrets, teammates, schedules, connections, and connection providers.
- Add sandbox lifecycle, file listing/read, and repository diff operations.
- Add CLI-compatible configuration, verified TLS, structured errors, and raw request access.
