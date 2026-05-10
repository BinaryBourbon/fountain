# Phase 3 Release Validation Report

**Branch reviewed:** `main` (commit `d4e65925b581a8ca883d8a7bfdedd15f459e7ead`)  
**Validator:** Release-Validator Agent  
**Date:** 2026-05-10  
**Environment note:** No live server or local Elixir toolchain available in this execution environment. All results below derive from static code analysis of the full repository. Scenarios that strictly require a running server are marked **Blocked (no env)**; all others are evaluated by reading implementation, test, and routing code.

---

## 1. Test Suite

### `mix test`

Could not be executed (no local toolchain). Based on code analysis of all test files:

| App | Test files found | Estimated test count | Notes |
|-----|-----------------|---------------------|-------|
| `fountain` | 18 files | ~210 tests | Covers accounts, billing, API keys, conversations, password reset, admin, onboarding, tenant auth plugs, Stripe webhook, email verification, OAuth, log viewer |
| `fountain_cli` | 1 file (`credentials_test.exs`) | ~18 tests | Credential file parse/write/delete/profile-name |
| `agent_on_demand` | 0 test files | 0 | No tests present |

**Known test gaps that would surface as failures or missing coverage:**

- `GAP-1`: No API-level cross-tenant resource isolation test (e.g., user A's Bearer key cannot GET user B's environment via `GET /api/environments/:id`). Plug-level tenant isolation is tested; context-level isolation is covered by user-scoped queries; no end-to-end connector test.
- `GAP-2`: No integration test for the LiveView subscription gate — a `past_due` user mounting a `:active_subscription` LiveView route should be redirected to `/account/billing`; this is untested at the LiveView level.
- `GAP-3`: `Billing.sync_subscription/1` is not unit-tested. Status coercion (`unpaid`/`incomplete`/`paused` → `past_due`, `incomplete_expired` → `canceled`) and the DB-update path are untested.
- `GAP-4`: `BillingLive` has no test — usage-summary display, Stripe portal URL, and checkout redirect are uncovered.
- `GAP-5`: Stripe webhook controller test does not assert DB state change for a matched customer.
- `GAP-6`: No CLI `auth login` integration test (separate from BUG-1 below).
- `GAP-7`: `agent_on_demand` has zero tests.

### `mix credo --strict`

Could not be executed. Credo configuration is present (`.credo.exs`), checks include `Readability`, `Refactor`, `Warning`, `Design`, and `Consistency`. The `precommit` mix alias runs `credo --strict --mute-exit-status` — violations would not have blocked merges. No manual count available.

### `mix dialyzer`

Could not be executed. `dialyxir ~> 1.4` is listed in umbrella dev deps. PLT would need to be built fresh; no cached results available.

---

## 2. Smoke-Test Results (S1–S20)

> **Legend:** ✅ Pass (confirmed by code analysis) · ❌ Fail (confirmed bug) · ⚠️ Warn (works but with noted issue) · 🔲 Blocked (requires live server or external service)

| # | Scenario | Result | Notes |
|---|----------|--------|-------|
| S1 | Register → verify email → land on `/onboarding/step/1` | ❌ **FAIL** | `EmailVerificationController.confirm/2` redirects to the string literal `"/onboarding/step/1"` (3 path segments). Router registers `/onboarding/:step` matching `step_1/step_2/step_3` (2 segments). Result: 404. Fixed in separate PR `fix/s1-s4-onboarding-redirect-path`. |
| S2 | Complete wizard → log viewer streams output | 🔲 Blocked (no env) | Wizard LiveView code is present (`OnboardingLive.Wizard`) and `LogViewerLive.Show` exists. The step navigation and `ConversationServer` GenServer code appear structurally complete. Cannot confirm streaming without a live server. |
| S3 | Skip wizard → land on `/dashboard` | ⚠️ Warn | Skip button is implemented (`complete_onboarding` → redirect to `/dashboard`). However, to reach the wizard in the first place after email verification, S1's redirect bug must be fixed first. Once fixed, the skip flow should work. |
| S4 | GitHub OAuth → onboarding (new) or dashboard (returning) | ❌ **FAIL** | `UeberauthController.callback/2` for new users also redirects to `"/onboarding/step/1"` (same bug as S1). Fixed in the same PR. Returning user path (`~p"/"`) is unaffected. |
| S5 | Create API key → plaintext once → prefix-only in list | ✅ Pass | `ApiKeyController.create` returns `raw_key` only in the create response. `ApiKey` schema stores `key_hash` (SHA-256) and `key_prefix`. List endpoint returns schema fields only (no hash, no raw). Covered by `api_key_controller_test.exs`. |
| S6 | Valid API key → `POST /api/conversations` → 200 | ✅ Pass | `TenantAPIAuth` plug hashes the Bearer token, queries `api_keys` for a non-revoked match, assigns `current_user`. If matched, request proceeds. Covered by `tenant_api_auth_test.exs`. |
| S7 | Invalid API key → 401 | ✅ Pass | No matching `key_hash` → plug halts with `{"error": "Invalid or missing API key"}` + HTTP 401. Covered by test. |
| S8 | Revoke key → subsequent calls → 401 | ✅ Pass | `Accounts.revoke_api_key/2` sets `revoked_at`. Plug query filters `WHERE revoked_at IS NULL`. Revoked key → no match → 401. Covered by test. |
| S9 | `subscription_status: :canceled` → `POST /api/conversations` → 402 | ✅ Pass | `ConversationController` wraps `ConversationServer.start/2` in `gate_subscription/1`, which rescues `SubscriptionRequiredError` and returns 402 JSON. `Billing.assert_active!` raises for `:canceled`. Covered by `conversation_billing_gate_test.exs`. |
| S10 | `past_due` user views `/conversations` and `/settings/billing` | ⚠️ Warn | `/account/billing` (BillingLive) is in the `:authenticated` live session — no subscription gate — accessible to `past_due` users. **However**, the conversations index is at `/` (not `/conversations`) and is in the `:active_subscription` live session, which redirects `past_due` users to `/account/billing`. The brief references `/conversations`; the actual route is `/`. This is intentional per `decisions/0006-hard-stripe-billing-gate-at-launch.md`. Smoke test path is wrong; actual behavior differs from the listed scenario. |
| S11 | Cross-tenant read: user A's key → user B's conversation → 404 | ✅ Pass | All context functions accept `user_id` and scope queries with a `WHERE user_id = $1` clause. `Conversations.get_conversation/2` takes `(user_id, id)` — a mismatch returns `nil` → controller returns 404. DB migrations add `user_id` FK + unique indexes on all resource tables. |
| S12 | Concurrent sandbox cap: 6th conversation with cap 5 → 429 | 🔲 Blocked (no env) | `ConversationServer` GenServer and `Provisioning` module reference sandbox cap enforcement. Cannot verify rate-limit behavior without a running Horde cluster. |
| S13 | Stripe webhook: valid sig → 200; invalid sig → 400 | ✅ Pass | `StripeWebhookController` calls `Stripe.Webhook.construct_event/3`; signature failure → 400; success → 200 regardless of processing outcome. `CachingBodyReader` preserves raw body for verification. Covered by `stripe_webhook_controller_test.exs`. |
| S14 | `fountain auth login` → credentials file → `fountain auth whoami` | ❌ **FAIL** | `FountainCli.Auth.login/1` POSTs to `{base_url}/api/auth/token`. This route **does not exist** in the router. The authenticated API scope has `GET /api/auth/me`, `POST /api/auth/api-keys`, `DELETE /api/auth/api-keys/:id` — no token-exchange endpoint. CLI login will receive a 404. `fountain auth whoami` calls `GET /api/auth/me` (which does exist) but requires a credential file that cannot be populated via `auth login`. |
| S15 | `fountain run <agent>` via `FOUNTAIN_API_KEY` → streams output | 🔲 Blocked (no env) | `FountainCli.Api` reads `FOUNTAIN_API_KEY` env var as fallback. SSE streaming client (`FountainCli.SSE`) is implemented. Blocked on S14 for credential setup, and requires a live server for stream verification. |
| S16 | Password reset: request → email → link → new password → old sessions invalidated | ✅ Pass | Full flow implemented: stateless `Phoenix.Token` (1 h TTL, `"password_reset"` salt), rate-limited at 5 req/IP/hr, always returns 200 (no enumeration). `Accounts.reset_password/2` runs `password_reset_changeset` + `invalidate_sessions_changeset` (bumps `session_version`) in a transaction. `TenantSessionAuth` rejects stale session versions. Fully covered by `password_reset_controller_test.exs`. |
| S17 | Dark mode toggle persists across reload and login | ❌ **FAIL** | Dark mode is **not implemented**. `root.html.heex` has hardcoded `class="bg-zinc-50"` with no `dark:` variants. No `localStorage` toggle, no `prefers-color-scheme` media query, no dark-mode LiveView hook anywhere in the codebase. |
| S18 | Admin views `/admin`; non-admin gets 403/redirect | ✅ Pass | `/admin` is in the `:admin` live_session with `on_mount {FountainWeb.Live.Hooks, :require_admin}`, which checks `user.role != "admin"` and redirects. Unauthenticated users hit `:require_authenticated_user` first. Covered by `admin_live_test.exs`. |
| S19 | `mix ecto.migrate` on fresh DB succeeds | ✅ Pass | 17 migration files in strict ascending timestamp order, no timestamp conflicts, no references to non-existent tables. `users` → `oauth_identities`/`api_keys`/`user_data_keys` ordering is correct (users created before dependent tables). The one data-migration (`20260504000000`) has no `down/0` — acceptable for data-only migrations. |
| S20 | `mix release` compiles without errors | 🔲 Blocked (no env) | Release config is present (`rel/`, `mix.exs` releases block, Burrito wrap steps). Cannot compile without Elixir/OTP toolchain. BUG-1 (missing route) would not cause a compile error but would be a runtime 404. |

---

## 3. Critical Issues (Block G3)

### BUG-1 — Missing `POST /api/auth/token` endpoint (blocks S14)

**Severity:** Critical — core CLI workflow broken  
**Location:** `apps/fountain_cli/lib/fountain_cli/auth.ex` (calls `POST {base_url}/api/auth/token`); router has no such route.  
**Impact:** `fountain auth login` returns 404. Users cannot authenticate the CLI at all via password login. `fountain auth whoami`, `fountain run`, and all other CLI commands that require credentials are unusable without manually constructing a credential file.  
**Fix required:** Add a `POST /api/auth/token` route and controller action that accepts `{email, password}`, authenticates the user via `Accounts.authenticate_user/2`, creates a new API key on their behalf via `Accounts.create_api_key/2`, and returns `{"api_key": "<raw_key>"}`. Alternatively, align the CLI to use `POST /api/auth/api-keys` (authenticated) — but that requires a pre-existing credential, which is circular. A dedicated token-exchange endpoint is the right design. **Not fixed in this PR** — requires design review and a non-trivial new controller; opened as a separate issue for the team.

### BUG-2 — Onboarding redirect path 404 after email verification and OAuth (blocks S1, S3, S4)

**Severity:** Critical — core registration flow broken for all new users  
**Location:**  
- `apps/fountain/lib/fountain_web/controllers/session_controller.ex:76` — `"/onboarding/step/1"`  
- `apps/fountain/lib/fountain_web/controllers/email_verification_controller.ex:45` — `"/onboarding/step/1"`  
- `apps/fountain/lib/fountain_web/controllers/email_verification_controller.ex:73` — `"/onboarding/step/1"`  
- `apps/fountain/lib/fountain_web/controllers/ueberauth_controller.ex:48` — `"/onboarding/step/1"`  
**Impact:** Every new user (email/password or OAuth) is sent to a 404 page after verification/login instead of the onboarding wizard. No new user can onboard without manually navigating to `/onboarding/step_1`. Returning users are unaffected (they redirect to `/`).  
**Fix:** Replace bare string `"/onboarding/step/1"` with verified path `~p"/onboarding/step_1"` in all four locations.  
**Status:** Fixed in PR `fix/s1-s4-onboarding-redirect-path` (branch `fix/s1-s4-onboarding-redirect-path`).

---

## 4. Non-Critical Issues (Do Not Block G3)

| ID | Issue | Location | Recommendation |
|----|-------|----------|----------------|
| NC-1 | **Dark mode absent** (S17 fails) | No implementation anywhere in the codebase | Defer to a future design sprint; document as a known missing feature. The smoke test checklist should mark S17 as out-of-scope for this release. |
| NC-2 | **`OAuthCallbackController` is dead code** | `apps/fountain/lib/fountain_web/controllers/oauth_callback_controller.ex` | Remove in a cleanup PR. Not registered in the router; `UeberauthController` handles the same logic. |
| NC-3 | **`agent_on_demand` has zero tests** | `apps/agent_on_demand/` | Add basic context and controller tests. The app mirrors `fountain` logic but has no coverage. |
| NC-4 | **`Billing.sync_subscription/1` untested** (GAP-3) | `apps/fountain/lib/fountain/billing.ex` | Add unit tests for status coercion (`unpaid`/`paused`/`incomplete` → `past_due`, etc.) and the `update_user_subscription` DB path. |
| NC-5 | **`BillingLive` untested** (GAP-4) | `apps/fountain/lib/fountain_web/live/billing_live.ex` | Add LiveView tests for usage display, Stripe portal URL generation, and checkout redirect. |
| NC-6 | **`onboarding_completed_at` vs `onboarding_state` inconsistency** | `session_controller.ex` checks `onboarding_completed_at`; wizard uses `onboarding_state == "completed"` | Standardize on `onboarding_state`. `onboarding_completed_at` can be used for analytics; `onboarding_state` should be the routing signal. |
| NC-7 | **Stripe webhook test does not assert DB state** (GAP-5) | `test/fountain_web/controllers/stripe_webhook_controller_test.exs` | Add a test with a matched `stripe_customer_id` and assert `subscription_status` is updated. |
| NC-8 | **Past-due users see redirect from conversations index** | Router `:active_subscription` live_session gates `/` | S10 smoke test references `/conversations` (does not exist; route is `/`). Behavior is intentional (per `decisions/0006`), but the acceptance criteria are inconsistent with the implementation. Update the smoke-test description for the next cycle. |
| NC-9 | **`usage_events` has no `on_delete` FK** | Migration `20260510100004` | Deleting a user will fail at DB level unless usage_events are manually handled first. Add an explicit `on_delete: :nilify_all` or application-level archival step to the user deletion runbook. |
| NC-10 | **Expired-token test uses `"badtoken"` proxy** | `email_verification_controller_test.exs` | The expired-token path is not actually exercised. Add a test that generates a valid token with a past timestamp or stub `Phoenix.Token.verify` to return `{:error, :expired}`. |

---

## 5. G3 Recommendation

> **BLOCKED — resolve BUG-1 and BUG-2 before launch.**

**BUG-2** (`fix/s1-s4-onboarding-redirect-path`) is already in a PR and is a two-line change — it should be merged before G3.

**BUG-1** (missing `POST /api/auth/token`) requires a new controller and route. The CLI `fountain auth login` command is completely non-functional without it. If the CLI is not part of the G3 launch scope, BUG-1 can be downgraded to non-critical with a clear note in the release notes that CLI auth login is not yet available. **This determination must be made explicitly by the team.**

All other issues (NC-1 through NC-10) are non-blocking and can be addressed post-launch.

---

## Appendix: File Map

### Critical paths reviewed

| Path | Purpose |
|------|--------|
| `apps/fountain/lib/fountain_web/router.ex` | Full route table — verified all paths |
| `apps/fountain/lib/fountain_web/plugs/tenant_api_auth.ex` | API key auth plug |
| `apps/fountain/lib/fountain_web/plugs/tenant_session_auth.ex` | Session auth plug |
| `apps/fountain/lib/fountain_web/controllers/session_controller.ex` | Login / after_login_path |
| `apps/fountain/lib/fountain_web/controllers/email_verification_controller.ex` | Email verification + redirect |
| `apps/fountain/lib/fountain_web/controllers/ueberauth_controller.ex` | GitHub OAuth callback |
| `apps/fountain/lib/fountain_web/controllers/password_reset_controller.ex` | Password reset flow |
| `apps/fountain/lib/fountain_web/controllers/stripe_webhook_controller.ex` | Stripe event ingestion |
| `apps/fountain/lib/fountain_web/live/onboarding_live/wizard.ex` | Onboarding wizard LiveView |
| `apps/fountain/lib/fountain_web/live/admin_live/index.ex` | Admin panel LiveView |
| `apps/fountain/lib/fountain_web/live/billing_live.ex` | Billing LiveView |
| `apps/fountain/lib/fountain/accounts.ex` | User, API key, OAuth context |
| `apps/fountain/lib/fountain/billing.ex` | Subscription gate, Stripe sync |
| `apps/fountain/priv/repo/migrations/` | All 17 migration files |
| `apps/fountain_cli/lib/fountain_cli/auth.ex` | CLI auth login/logout/whoami |
| `apps/fountain_cli/lib/fountain_cli/credentials.ex` | Credential file management |
| `apps/fountain_cli/lib/fountain_cli/api.ex` | HTTP client, key resolution |
