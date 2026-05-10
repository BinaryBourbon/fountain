## Context

G2 locked. Build starts now. The full engineering plan is at `plan/phase-2-build-plan/engineering-plan.md`. Read it and `decisions/0004`, `0005`, `0006` before writing any code.

Your slice is **tenant context scoping**: refactor every aod-ex context module so that all list/get/create/delete functions are scoped to an authenticated `user_id`. A parallel slice (`phase-3-foundation`) is simultaneously adding the `users` table and `user_id` FK columns to existing tables; write your code against the schema specified in the engineering plan §1.2 and it will integrate when both PRs merge (foundation first, then this one).

Do not touch `lib/fountain/accounts/`, `lib/fountain/crypto.ex`, migrations, `mix.exs`, or `render.yaml` — those are owned by the foundation slice.

## Task

Work on branch `phase-3-tenant-contexts`, starting from the aod-ex codebase (or the `phase-3-foundation` branch if it has merged). Make all changes within the umbrella app `apps/agent_on_demand/` (renamed to `apps/fountain/` by the foundation slice).

- **Tenant-scope all context functions** per engineering plan §3.1:
  - `Fountain.Environments`: `list_environments(user_id)`, `get_environment!(id, user_id)`, `create_environment(attrs, user_id)`, `update_environment/3`, `delete_environment/2`.
  - `Fountain.Agents`: same pattern.
  - `Fountain.Vaults`: same pattern; also scope `list_vault_secrets/2` and all vault secret CRUD.
  - `Fountain.Conversations`: `list_conversations(user_id)`, `get_conversation!(id, user_id)`, `start_conversation(attrs, user_id)` — validate `agent.user_id == user_id` and `vault.user_id == user_id` before starting.
  - All queries gain `where: [user_id: ^user_id]`; cross-tenant access returns `Ecto.NoResultsError` (surfaced as 404).
- **Update `ConversationServer`** per §3.4: accept `user_id` in start args; call `Fountain.Crypto.load_tenant_key(user_id)` in `init/1`; store DEK in GenServer state; pass to all `Crypto.decrypt/2` calls; zero the field in `terminate/2`.
- **SSE stream isolation** per §3.2: in `ConversationController.stream/2`, call `get_conversation!(id, current_user.id)` before subscribing to the PubSub topic. Reject with 404 if not owner.
- **PubSub topic namespacing** per UX spec: change `"conv:<id>"` to `"conv:<user_id>:<conversation_id>"` throughout (broadcast in `ConversationServer`, subscription in the SSE controller, and in `LogViewerLive` when it exists).
- **Implement `Fountain.Quotas`** per §4.1: `check_sandbox_quota!(user_id)` — counts active sandboxes for the user, raises `Fountain.Quotas.QuotaExceededError` if at or above `user.max_concurrent_sandboxes`. Call it in `ConversationServer.init/1` before `Sprites.create/2`.
- **Implement `Fountain.Billing.emit/5`** per §5.1: writes a `usage_events` row synchronously. Call it at the three emission points in `ConversationServer` (`sandbox_provisioned`, `turn_started`, `sandbox_terminated`).
- **Update existing aod-ex REST controllers** to extract `current_user` from `conn.assigns` (set by the auth plug from the foundation slice) and thread `current_user.id` into every context call.
- **Update existing aod-ex LiveViews** (`agents_live`, `conversations_live`, `environments_live`, `vaults_live`, `audit_live`) to use the `on_mount :require_authenticated_user` hook and scope all context calls to `current_user.id`.

## Acceptance

- PR `phase-3-tenant-contexts` against `main` on `BinaryBourbon/fountain` (or against `phase-3-foundation` if it hasn’t merged yet — note this in the PR description).
- Every context function in the four modules accepts and enforces `user_id`.
- A cross-tenant read attempt (wrong `user_id`) returns `Ecto.NoResultsError` from every `get_*!` function.
- `ConversationServer` loads and stores the per-tenant DEK in init, passes it to crypto calls.
- `Fountain.Quotas.check_sandbox_quota!/1` raises correctly when the count is at the cap.
- `Fountain.Billing.emit/5` writes a `usage_events` row.
- All three emission points in `ConversationServer` call `Billing.emit/5`.
- PubSub topics are `"conv:<user_id>:<conversation_id>"` throughout.
- Existing LiveViews use `on_mount :require_authenticated_user`.
- No new test failures introduced (existing aod-ex tests updated to pass `user_id` where required).

## Out of scope

- Do not implement new LiveViews (onboarding wizard, log viewer, billing UI, API keys UI) — those are later slices.
- Do not implement auth plugs, controllers, or registration — that is `phase-3-auth`.
- Do not modify `mix.exs`, migrations, or `render.yaml` — foundation slice owns those.
- Do not implement `Fountain.Billing.assert_active!/1` or the Stripe gate — that is `phase-3-billing`.
