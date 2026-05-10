## Context

All functional slices have merged into `main`: foundation, tenant contexts, auth, CLI, billing, and onboarding LiveViews. A parallel `phase-3-design-pass` is running but touches only CSS/components — your work is independent. This is the pre-G3 smoke test and release validation pass.

Your job is to run the test suite, execute a structured smoke-test checklist against a local or test environment, and produce a validation report. You are read-only except for writing the report and any minimal bug-fix PRs for critical issues you find. Do not implement new features.

## Task

Branch `phase-3-release-validation` from `main`.

**1. Test suite**
- Run `mix test` across the full umbrella. Record pass/fail counts and any failing tests.
- Run `mix credo --strict` and `mix dialyzer` (or `mix dialyxir`). Record warnings.

**2. Smoke-test checklist** — execute each scenario against a local `mix phx.server` (or test environment). Document pass/fail and any error output for each:

| # | Scenario |
|---|---|
| S1 | Register a new account → receive verification email → click link → land on `/onboarding/step/1` |
| S2 | Complete the wizard (create env + agent + first conversation) → log viewer streams output |
| S3 | Skip the wizard from step 1 → land on `/dashboard` |
| S4 | Log in with GitHub OAuth → land on `/onboarding` (new user) or `/dashboard` (returning) |
| S5 | Create an API key → copy plaintext once → key appears in list with prefix only |
| S6 | Use the API key to `POST /api/conversations` → 200 |
| S7 | Use an invalid API key → 401 |
| S8 | Revoke an API key → subsequent API calls with that key → 401 |
| S9 | Simulate expired trial (set `subscription_status: :canceled`) → `POST /api/conversations` → 402 |
| S10 | `past_due` user can still view `/conversations` and `/settings/billing` |
| S11 | Cross-tenant read attempt: user A’s API key requests user B’s conversation → 404 |
| S12 | Concurrent sandbox cap: create 6 conversations with `max_concurrent_sandboxes: 5` → 6th returns 429 |
| S13 | Stripe webhook with valid signature → 200; invalid signature → 400 |
| S14 | `fountain auth login` CLI → writes credentials file → `fountain auth whoami` reads it |
| S15 | `fountain run <agent> -p "hello"` using `FOUNTAIN_API_KEY` env var → streams output |
| S16 | Password reset flow: request → email → click link → set new password → old sessions invalidated |
| S17 | Dark mode toggle: persists across page reload and across login |
| S18 | Admin user can view `/admin` with all active sandboxes; non-admin gets 403/redirect |
| S19 | `mix ecto.migrate` runs cleanly on a fresh DB (all migrations succeed in order) |
| S20 | `mix release` compiles without errors (production build) |

**3. Validation report**
- Write `plan/phase-3-release-validation/validation-report.md` with:
  - Test suite results (pass/fail counts, any failures with stack traces).
  - Credo + Dialyzer warning counts.
  - Smoke-test results table (S1–S20: Pass / Fail / Blocked + notes).
  - **Critical issues** (block G3): any scenario that fails with a security, data-loss, or auth-bypass implication.
  - **Non-critical issues** (do not block G3): cosmetic, UX, or minor functional gaps.
  - **G3 recommendation**: “Ready” or “Blocked — resolve [issue list] before launch.”

**4. Critical bug fixes only**
- If you find a critical issue (auth bypass, cross-tenant data leak, crash on a core flow), open a separate minimal PR fixing only that issue. Reference the scenario number in the PR title.
- Do not fix non-critical issues in this slice — log them in the report for the operator to triage.

## Acceptance

- PR `phase-3-release-validation` against `main` containing only `plan/phase-3-release-validation/validation-report.md` (plus any critical bug-fix commits, each in their own PR).
- Every smoke-test scenario has a recorded result (Pass / Fail / Blocked with notes).
- The G3 recommendation is clearly stated.
- No new features, refactors, or non-critical fixes introduced.

## Out of scope

- Do not implement design changes — that is `phase-3-design-pass`.
- Do not fix non-critical issues — report them only.
- Do not run load or performance tests — those are post-launch.
