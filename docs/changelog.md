# Changelog

This page mirrors [`CHANGELOG.md`](https://github.com/BinaryBourbon/fountain/blob/main/CHANGELOG.md) in the repo root.

---

## [Unreleased]

### Added
- Context-level ExUnit tests for `Agents`, `Environments`, `Vaults`, `Audit`, and `Substitution`
- StreamData property-based tests for `Fountain.Substitution`
- GitHub Actions CI pipeline: format check, compile warnings-as-errors, Credo, DB migrate, full suite
- `CLAUDE.md` contributor guide
- This public documentation site

### Changed
- Test DB pool size raised from 5 to 20 to support concurrent async test modules
- `require_admin` LiveView hook now uses `push_navigate` for authenticated non-admin users

### Fixed
- `PasswordResetController` returns `422` on validation failure (was `200`)
- Rate limiter uses PID-based isolation in test mode
- `UeberAuthController` skips `plug Ueberauth` in test mode

---

## [0.1.0] - 2026-04-01

### Added
- Multi-tenant API and UI for Agents, Environments, Vaults, and Conversations
- GitHub OAuth, Stripe billing, per-tenant envelope encryption
- Sprites sandbox integration with streaming log events
- LiveView UI, REST API with API-key auth, per-tenant rate limiting
- `fountain` CLI with `auth`, `apply`, `get`, `describe`, `delete`, `run`
- `/llms.txt`, `/llms-full.txt`, `/skill` for LLM-native API discovery
- Audit log, substitution engine
