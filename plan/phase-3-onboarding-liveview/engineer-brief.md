## Context

Auth is merged. `on_mount :require_authenticated_user`, all session/API key plugs, `Fountain.Accounts`, and the scoped context modules are in `main`. The full UX spec is at `plan/phase-2-build-plan/ux-spec.md` — this is your primary spec. Read all five flows. The engineering plan `plan/phase-2-build-plan/engineering-plan.md` §6 covers the LiveView refactor scope. Read both before writing any code.

A parallel slice (`phase-3-billing`) is running at the same time and owns `billing_live.ex` and the Stripe webhook controller. You own the four new LiveViews below and the updates to existing LiveViews. Both slices touch `router.ex` — add routes in clearly separated, labelled blocks.

## Task

Branch `phase-3-onboarding-liveview` from `main`.

- **`FountainWeb.Live.OnboardingLive`** at `/onboarding/step/:step` per UX spec §1:
  - Step 1: Environment form (name, packages, env vars/secrets, repos, networking type, setup script). “Skip for now” link. Save to DB on advance.
  - Step 2: Agent form (name, runtime, model dropdown filtered by runtime, system prompt, environment dropdown, MCP servers repeating, skills repeating with inline/github toggle). Back link. Save to DB on advance.
  - Step 3: First conversation (agent pre-selected, vault dropdown, prompt textarea). On submit: `POST /api/conversations`, redirect to `/conversations/:id`.
  - Progress indicator (1/3, 2/3, 3/3). Persistent “Skip wizard” link on every step. Skipping sets `onboarding_completed_at` and redirects to `/dashboard`.
  - Re-entry: users who have not completed the wizard are redirected here after login. Resume from the correct step based on `onboarding_state`.
  - Post-wizard: dismissible banner on the dashboard — “You’re up and running.”
- **`FountainWeb.Live.LogViewerLive`** per UX spec §4 and engineering plan §6.2:
  - Mount: load conversation via `get_conversation!(id, current_user.id)` — 404 if not owner.
  - Replay `log_events` from integer cursor (all if no cursor). Subscribe to PubSub `"conv:<user_id>:<conversation_id>"`.
  - Render `output` events as monospace lines (stdout default, stderr muted red). Render `stage` events as lifecycle banners.
  - Auto-scroll to bottom; pause on user scroll-up; “Jump to bottom” button.
  - Follow-up input pinned at bottom: enabled when status `ready` and no turn in flight; disabled with tooltip when `pending`/`starting`; hidden when `terminated`/`failed`.
  - On follow-up submit: `POST /api/conversations/:id/prompts`.
  - Terminate button: confirmation modal → `POST /api/conversations/:id/terminate`.
  - Turn history sidebar (collapsible, collapsed by default on narrow viewports): turn number, prompt excerpt, exit code, duration. Click scrolls to that turn’s first log line.
  - Route: both embedded in `ConversationsLive` (show view) AND standalone at `/conversations/:id/logs`.
- **`FountainWeb.Live.ApiKeysLive`** at `/settings/api-keys` per UX spec §5a:
  - List: key name, prefix, created, last used, revoke button.
  - Create: modal with name field → `POST /api/auth/api-keys` → one-time plaintext display with copy-to-clipboard JS hook + “This key will not be shown again” warning.
  - Revoke: confirmation modal → `DELETE /api/auth/api-keys/:id`.
- **`FountainWeb.Live.AdminLive`** at `/admin` (admin role only, `on_mount :require_admin` hook) per engineering plan §6.2:
  - Lists all active sandboxes across tenants: sprite name, status, user email, conversation ID link.
  - Link to read-only `LogViewerLive` for any conversation.
- **Update existing LiveViews** per engineering plan §6.1: confirm `agents_live`, `conversations_live` (list), `environments_live`, `vaults_live`, `audit_live` all use `on_mount :require_authenticated_user` and scope every query to `current_user.id`. Embed `LogViewerLive` component inside `conversations_live` show view.
- **Dashboard route**: add `/dashboard` as the post-login landing. Can be a simple LiveView that lists recent conversations and links to resources — not specified in the UX spec, but needed as the redirect target.

## Acceptance

- PR `phase-3-onboarding-liveview` against `main`.
- `mix compile` and `mix test` pass. Tests cover: onboarding wizard step advance/skip/re-entry, LogViewerLive ownership check (404 on wrong user), ApiKeysLive create + one-time display, AdminLive access denied for non-admin.
- A user who skips the wizard lands on `/dashboard`, not `/onboarding`.
- LogViewerLive refuses to mount for a conversation owned by a different user.
- `on_mount :require_authenticated_user` is present on all five new and updated LiveViews.
- Auto-scroll pauses when the user scrolls up and resumes on “Jump to bottom” click.

## Out of scope

- Do not implement `BillingLive` or Stripe webhook controller — that is `phase-3-billing`.
- Do not implement the full design system (dark mode tokens, component library) — the designer will apply that in a separate pass before G3.
- Do not implement org/team features — deferred per decisions/0003.
- Do not implement `UsageLive` (`/settings/usage`) — it can be a stub route that renders a placeholder until billing is live.
