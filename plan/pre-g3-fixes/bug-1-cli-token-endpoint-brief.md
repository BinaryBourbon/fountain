## Context

The release validator identified a critical bug: `fountain auth login` calls `POST /api/auth/token` but this route does not exist in the router. Every CLI user who tries to log in via password receives a 404 and cannot authenticate. `fountain auth whoami`, `fountain run`, and all credential-dependent CLI commands are broken as a result.

This is the only change in this fix. Do not touch any other file.

## Task

Branch `fix/bug-1-cli-token-endpoint` from `main` (or from `fix/s1-s4-onboarding-redirect-path` if that has not yet merged).

- Add `POST /api/auth/token` to the `:browser_public` scope in `router.ex` (no auth required — this is the credential-exchange endpoint).
- Implement `FountainWeb.AuthTokenController.create/2`:
  - Accept `{email, password}` JSON body.
  - Call `Fountain.Accounts.authenticate_user(email, password)` — returns `{:ok, user}` or `{:error, :invalid_credentials}`.
  - On success: call `Fountain.Accounts.create_api_key(user, %{name: "CLI login — #{DateTime.utc_now() |> DateTime.to_date()}"})` to mint a fresh API key, then return `201 {"api_key": "<raw_key>", "key_id": "<id>", "prefix": "<prefix>"}`.
  - On failure: return `401 {"error": "Invalid email or password"}`.
  - Rate-limit: 10 attempts per IP per hour (reuse the existing `rate_limit.ex` module).
- Add `Fountain.Accounts.authenticate_user/2` to the Accounts context if not already present: query user by email, verify `Bcrypt.verify_pass(password, user.password_hash)`, return `{:ok, user}` or `{:error, :invalid_credentials}`. Guard against timing attacks with `Bcrypt.no_user_verify()` when no user is found.
- Write tests in `test/fountain_web/controllers/auth_token_controller_test.exs`: valid credentials → 201 with `api_key`; invalid credentials → 401; rate limit (11th attempt from same IP) → 429.

## Acceptance

- PR `fix/bug-1-cli-token-endpoint` against `main`.
- `mix test` passes including the new controller tests.
- `POST /api/auth/token` with valid credentials returns 201 and a raw API key.
- `POST /api/auth/token` with wrong password returns 401.
- The raw key returned can subsequently authenticate `GET /api/auth/me` via `Authorization: Bearer <key>`.
- No other files changed.

## Out of scope

- Do not modify CLI code — `FountainCli.Auth.login/1` already targets this endpoint correctly.
- Do not implement refresh tokens or JWT — API keys are the session token.
- Do not fix any NC-* issues from the validation report.
