# Changelog

All notable changes to Fountain are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

Versions track the public API and notable behavioural changes. Internal refactors, test additions, and doc updates are noted but don't bump the version on their own.

---

## [Unreleased]

### Added
- Context-level ExUnit tests for `Agents`, `Environments`, `Vaults`, `Audit`, and `Substitution` (all `async: true`, using `DataCase` + factory helpers)
- StreamData property-based tests for `Fountain.Substitution`
- GitHub Actions CI pipeline (`.github/workflows/ci.yml`): format check, compile with warnings-as-errors, Credo, DB migrate, full test suite
- `CLAUDE.md` contributor guide covering architecture, test patterns, tenant isolation contract, and things to avoid

### Changed
- Test DB `pool_size` raised from 5 → 20 to support concurrent async test modules without connection timeouts
- `require_admin` LiveView hook now uses `push_navigate` (live redirect) for authenticated non-admin users instead of a hard HTTP redirect, making the hook testable with `{:live_redirect, _}` assertions
- `advance_onboarding/2` guard extended to include `"step_4"` (wizard has four steps)

### Fixed
- `PasswordResetController` now returns `422 Unprocessable Entity` (was `200 OK`) on validation failure
- Rate limiter keyed by calling process PID in test mode so async tests don't share ETS counters
- `UeberAuthController` skips `plug Ueberauth` in test mode to prevent OAuth plug from overwriting manually-set `conn.assigns`

---

## [0.1.0] — 2026-04-01

### Added
- Multi-tenant API and UI for managing Agents, Environments, Vaults, and Conversations
- GitHub OAuth login via Ueberauth
- Stripe billing integration with subscription enforcement
- Per-tenant envelope encryption for secrets (AES-256-GCM, per-tenant DEK)
- Sprites sandbox platform integration (spawn / poll / stream log events)
- LiveView UI: dashboard, agent editor, environment/vault editors, conversation viewer, admin panel
- REST API with API-key authentication and per-tenant rate limiting
- `fountain` CLI (`cli/`) with `auth`, `apply`, `get`, `describe`, `delete` commands
- `llms.txt` / `llms-full.txt` / `/skill` endpoints for LLM-native API discovery
- Audit log for state-changing actions (append-only, best-effort)
- Substitution engine for `${VAR}` / `$$` interpolation in agent configs
