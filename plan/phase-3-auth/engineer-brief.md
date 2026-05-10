## Context

The foundation and tenant-context slices have merged. `Fountain.Accounts` (User, ApiKey, UserDataKey, OauthIdentity), `Fountain.Crypto`, and all migrations are in `main`. Every context module (Environments, Agents, Vaults, Conversations) is now scoped by `user_id`. The full engineering plan is at `plan/phase-2-build-plan/engineering-plan.md` (§2 Auth Architecture). Read it and the UX spec at `plan/phase-2-build-plan/ux-spec.md` (§1 Onboarding, §5a API Keys) before writing any code.

This slice owns everything between an HTTP request arriving and `conn.assigns.current_user` or `socket.assigns.current_user` being set. A parallel slice (`phase-3-cli`) is running at the same time but touches only `apps/fountain_cli/` — no overlap.

## Task

Branch `phase-3-auth` from `main`. Implement:

- **`FountainWeb.Plugs.TenantAPIAuth`** per §2.3: extract `Authorization: Bearer <key>`, SHA-256 hash, query `api_keys`, load user, set `conn.assigns.current_user`, update `last_used_at` via `Task.async`. Return 401 on failure.
- **`FountainWeb.Plugs.TenantSessionAuth`** per §2.3: read `user_id` from session, load user, set `current_user`, redirect to `/auth/login` if absent.
- **`FountainWeb.Live.Hooks`**: `on_mount :require_authenticated_user` (halt + redirect if no current_user or email unverified); `on_mount :require_admin` (halt if `user.role != "admin"`).
- **Router pipelines** per §2.3: `:api` (TenantAPIAuth), `:browser_authenticated` (TenantSessionAuth), `:browser_public` (no auth check). Wire all existing resource routes through `:api` / `:browser_authenticated` as appropriate.
- **`FountainWeb.RegistrationController`**: `GET /auth/register` (render form), `POST /auth/register` (create user, enqueue verification email via Swoosh, return 201/redirect). `POST /api/auth/register` (JSON path). Rate-limited: 5 registrations/IP/hour via carried-forward `rate_limit.ex`.
- **`FountainWeb.EmailVerificationController`**: `GET /users/confirm/:token` — verify `Phoenix.Token` (24h TTL), set `email_verified_at`, set session cookie, redirect to `/onboarding/step/1`.
- **`FountainWeb.SessionController`** (extend existing): `GET /auth/login` (form), `POST /auth/login` (validate credentials, set session), `GET /auth/logout` (clear session + redirect).
- **Password reset** per §2.5: `POST /api/auth/forgot` (rate-limited 5/hour/IP, always 200), `GET /auth/reset/:token`, `POST /auth/reset` (update hash, bump `session_version`, redirect).
- **GitHub OAuth** per §2.4 using `ueberauth` + `ueberauth_github`: `GET /auth/oauth/github`, `GET /auth/oauth/github/callback`. Upsert user by primary email; skip email verification for GitHub-verified emails; create `oauth_identities` row; redirect to `/onboarding/step/1` (new) or `/dashboard` (existing).
- **`POST /api/auth/api-keys`** and **`DELETE /api/auth/api-keys/:id`** controller actions (API key issuance and revocation per §2.2 + UX spec §5a). Return full plaintext key on creation only.
- **Swoosh email config**: configure Swoosh adapter for dev (local mailbox) and prod (SMTP via env vars `SMTP_HOST`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`, `SMTP_FROM`). Write two email templates: verification email and password-reset email.
- **`GET /api/auth/me`**: returns `{id, email, role, subscription_status}` for `fountain auth whoami` CLI support.

## Acceptance

- PR `phase-3-auth` against `main` on `BinaryBourbon/fountain`.
- `mix compile` passes. `mix test` passes (add tests for TenantAPIAuth, TenantSessionAuth, registration, email verification, password reset, API key issuance/revocation).
- Cross-tenant API request (wrong API key) returns 401.
- Unverified-user session request is redirected.
- GitHub OAuth callback creates a user + oauth_identities row in tests (mock ueberauth callback).
- Rate limiter blocks the 6th registration from the same IP in the same hour.
- No route in `:api` pipeline is reachable without a valid API key.

## Out of scope

- Do not implement new LiveViews (onboarding wizard, log viewer, billing UI) — later slices.
- Do not implement Stripe or billing logic — `phase-3-billing`.
- Do not touch `apps/fountain_cli/` — that is `phase-3-cli`.
- Do not implement `GET /api/auth/api-keys` list endpoint — include it in the API keys LiveView slice.
