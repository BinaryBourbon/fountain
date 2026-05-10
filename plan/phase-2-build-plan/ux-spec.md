# Fountain UX Spec — Phase 2

## Overview

This document specifies the user-facing flows for Fountain's Phoenix LiveView dashboard. Each flow is described as a numbered step sequence with key states and decisions. Engineering requirements derived from each flow are called out at the end of each section.

Fountain is Option B: API + Hosted UI + Self-Serve Onboarding. All resources are tenant-scoped. The reference for the existing LiveView surfaces is `jhgaylor/aod-ex`, which covers Environments, Agents, Conversations, and Vaults for a single operator. Fountain rebuilds those surfaces for multi-tenant use and adds onboarding, a log viewer, and an account/settings surface.

---

## 1. Onboarding Wizard

**Goal:** A new user arrives at the site, signs up, verifies their email, defines their first Environment and Agent, and starts their first Conversation — without reading documentation or filing a ticket.

### Steps

1. **Landing / sign-up page** (`/register`)
   - Form: email, password, password confirmation.
   - On submit: account created in `pending_verification` state; verification email sent; user sees a "Check your email" confirmation screen.
   - Inline validation: email format, password minimum length. No client-side uniqueness check (avoid timing-based enumeration).
   - Duplicate email: show a generic message — "If that address is registered, you'll receive a verification email" — to avoid account enumeration.

2. **Email verification** (`/verify-email?token=<signed_token>`)
   - On click: Phoenix-signed token validated, TTL 24 h. User state transitions to `active`. Session cookie set. Redirect to `/onboarding/step/1`.
   - Error states:
     - Expired token: "This link has expired." + "Resend verification email" button → `POST /api/auth/resend-verification`.
     - Already-used token: "This link has already been used." + redirect to `/login`.

3. **Onboarding step 1 — Environment** (`/onboarding/step/1`)
   - One-line explanation: "An Environment defines the packages, repositories, and secrets your agent will have access to."
   - Form fields:
     - Name (required)
     - Packages: optional, repeating key/value pairs (package manager + package names)
     - Env vars / secrets: optional, repeating key/value pairs — each pair becomes a Secret on the Environment
     - Repositories: optional, repeating entries — repo URL, mount path, secret key (references an env var key from above)
     - Networking type: dropdown (`limited` | `open`), default `limited`
     - Setup script: optional textarea
   - "Skip for now" link: skips Environment creation; agent in step 2 will have no environment attached.
   - On save: `POST /api/environments`, then `POST /api/environments/:id/secrets` for each env var entered.
   - Progress indicator: Step 1 of 3.

4. **Onboarding step 2 — Agent** (`/onboarding/step/2`)
   - One-line explanation: "An Agent is the AI model and instructions that run inside your Environment."
   - Form fields:
     - Name (required)
     - Runtime: dropdown (`claude` | `codex` | `gemini`), default `claude`; selecting a runtime updates the Model dropdown
     - Model: dropdown filtered by runtime (e.g. claude → `anthropic/claude-sonnet-4-6`, `anthropic/claude-opus-4-6`)
     - System prompt: optional textarea
     - Environment: pre-selected to the environment created in step 1 (if any); dropdown if more than one exists
     - MCP servers: optional — "Add MCP server" opens a sub-form per entry: Name + URL
     - Skills: optional — "Add skill" opens a sub-form per entry with a toggle between *GitHub source* (`source` + optional `name`) and *Inline* (`name` + `content` textarea)
   - Back link to step 1.
   - On save: `POST /api/agents`.
   - Progress indicator: Step 2 of 3.

5. **Onboarding step 3 — First Conversation** (`/onboarding/step/3`)
   - One-line explanation: "Start a conversation to see your agent run."
   - Form fields:
     - Agent: pre-selected to the agent created in step 2; not editable in the wizard.
     - Vault: dropdown — `— No vault —` (default) + any existing vaults. In the onboarding flow, no vaults exist yet; the dropdown shows only the default.
     - Prompt: textarea, required. Placeholder: "Say hello, then summarize what you can do."
   - On submit: `POST /api/conversations`. Redirect immediately to `/conversations/:id`.
   - Progress indicator: Step 3 of 3.

6. **Post-onboarding state**
   - User lands on the conversation show page (Flow 4) with a dismissible banner: "You're up and running. Explore Environments, Agents, and Vaults in the sidebar."
   - `onboarding_state` column on the user record transitions to `completed`.
   - Subsequent logins go directly to `/conversations`.
   - Re-entry: if a user abandons the wizard partway, the next login redirects them to the step they left at (tracked via `onboarding_state: step_1 | step_2 | step_3 | completed`).

### Engineering requirements

- `users` table: `email`, `hashed_password`, `state` (`pending_verification | active`), `onboarding_state` (`step_1 | step_2 | step_3 | completed`).
- `POST /api/auth/register` — creates user in `pending_verification` state, enqueues verification email. No auth token returned until verified.
- `GET /verify-email?token=<signed_token>` — validates token, transitions user to `active`, sets session cookie, redirects to `/onboarding/step/1`.
- `POST /api/auth/resend-verification` — rate-limited; same generic response regardless of whether the email exists.
- Onboarding step routes require `active` session but not `onboarding_state: completed`, so a user can re-enter the wizard after an incomplete first run.
- Steps 1 and 2 are skippable; step 3 requires an Agent to exist (redirect to step 2 if not).
- Wizard does not create a Vault — Vault management is in Flow 3.

---

## 2. Agent Configuration

**Goal:** A user creates or edits an Agent, configuring its model, system prompt, runtime, skills, environment, and MCP servers.

### Create flow

1. **Agents list** (`/agents`)
   - Table columns: Name, Runtime, Model, Environment (name or "—"), Created, Actions (Edit, Delete).
   - "New Agent" button → `/agents/new`.
   - Empty state: "No agents yet. Create your first agent to get started."
   - Pagination: server-side, 25 per page.

2. **New Agent form** (`/agents/new`)
   - Fields:
     - **Name** (required): short identifier, unique per tenant.
     - **Runtime** (required): dropdown — `claude`, `codex`, `gemini`. Default: `claude`. Changing runtime resets the Model selection.
     - **Model** (required): dropdown filtered by runtime. Values come from a static capability manifest embedded in the UI (a `GET /api/runtimes` endpoint is optional at launch).
     - **System prompt** (optional): textarea. Placeholder: "You are a helpful coding assistant."
     - **Environment** (optional): dropdown of the user's Environments. First option: `— None —`.
     - **MCP servers** (optional): repeating sub-form. Each entry: Name (display label), URL (HTTP or WS endpoint). "Add MCP server" / "Remove" buttons.
     - **Skills** (optional): repeating sub-form. Each entry has a mode toggle:
       - *GitHub source*: `source` field (e.g. `anthropics/skills`) + optional `name` (specific skill within that repo). Omit `name` to install all skills in the repo.
       - *Inline*: `name` + `content` textarea (full SKILL.md body).
       "Add skill" / "Remove" buttons. Order is preserved and determines mount order on the Sprite.
   - Validation: Name and Runtime and Model are required. MCP URL must parse as a valid URL. Inline skill requires both name and content.
   - "Save" → `POST /api/agents`. On success: redirect to `/agents` with flash "Agent created.".
   - "Cancel" → `/agents`.

3. **Edit Agent form** (`/agents/:id/edit`)
   - Same form, pre-populated. Skills and MCP servers render existing entries; user can add, remove, or reorder.
   - "Save" → `PUT /api/agents/:id`.
   - Editing an Agent does not affect Conversations already in progress — the UI should display a note: "Changes to this agent apply to new conversations only."

4. **Delete Agent**
   - Confirmation modal: "Delete agent <name>? This cannot be undone. Existing conversations will retain their history but cannot resume."
   - `DELETE /api/agents/:id`.
   - If the agent has active (non-terminated) conversations: API returns 409; UI displays "This agent has active conversations. Terminate them before deleting."

### Key states

- **Form validation error**: inline, field-level. Summary banner if multiple errors.
- **Save in progress**: primary button shows spinner, form inputs disabled.
- **Save success**: redirect + flash.
- **Save failure (API error)**: error banner above the form, form re-enabled.

### Engineering requirements

- `GET /api/agents` — paginated (cursor or offset), tenant-scoped. Response includes `environment_name` for display.
- `POST /api/agents` — body: `{name, runtime, model, system_prompt?, environment_id?, mcp_servers: [{name, url}], skills: [{source?, name?, content?}]}`.
- `PUT /api/agents/:id` — full replace of the agent record including skills and MCP servers arrays.
- `DELETE /api/agents/:id` — returns 409 if active conversations exist.
- Skills with `source` are stored as pointers; resolution happens on the Sprite at conversation start. The API must not attempt GitHub resolution at save time.
- A static capability manifest (runtime → model list) embedded in the UI is sufficient at launch. If a `GET /api/runtimes` endpoint is added later, the UI can switch to it without a flow change.

---

## 3. Vault Management

**Goal:** A user creates a Vault, adds or edits its secrets, and selects it when starting a Conversation.

### Create Vault

1. **Vaults list** (`/vaults`)
   - Table columns: Name, Description, Secret count, Created, Actions (Edit, Delete).
   - "New Vault" button → `/vaults/new`.
   - Empty state: "No vaults yet. Vaults let you override credentials per conversation — useful for running the same agent under different GitHub identities or API keys."

2. **New Vault form** (`/vaults/new`)
   - Fields:
     - **Name** (required, unique per tenant): short identifier.
     - **Description** (optional): one-line explanation (e.g. "Alice's personal GitHub credentials").
   - "Save" → `POST /api/vaults`. On success, redirect to `/vaults/:id/edit` so the user can immediately add secrets.

### Edit Vault / Secrets

3. **Vault detail / edit** (`/vaults/:id/edit`)
   - **Metadata section**: Name and Description fields. "Update" saves `PUT /api/vaults/:id`.
   - **Secrets section** (below metadata):
     - Table: Key, Value (always masked as `••••••••`), Created, Delete button.
     - "Add secret" inline form at the bottom of the table: Key (text, required) + Value (password input, required) + "Add" button → `POST /api/vaults/:id/secrets`.
     - Delete secret → `DELETE /api/vaults/:id/secrets/:key` with a confirmation: "Delete secret <key>? This cannot be undone."
     - Values are **write-only**: the UI never displays plaintext. To update a value, the user must delete the key and re-add it. The "Value" column always shows `••••••••` regardless of how the secret was added.
   - Inline note below the secrets table: "Vault secrets override Environment secrets with the same key when this vault is selected for a conversation."

4. **Delete Vault**
   - Confirmation modal: "Delete vault <name>? Conversations that used this vault will retain their history."
   - `DELETE /api/vaults/:id`.

### Select Vault when starting a Conversation

- The Vault dropdown appears on both the "New Conversation" form (`/conversations/new`) and the onboarding wizard step 3.
- Options: `— No vault —` (default) + all tenant vaults listed by name.
- Selecting a vault is always optional.

### Engineering requirements

- `GET /api/vaults` — paginated, tenant-scoped. Response includes `secret_count` for the list view.
- `POST /api/vaults` — body: `{name, description?}`.
- `PUT /api/vaults/:id` — body: `{name, description?}`.
- `DELETE /api/vaults/:id`.
- `GET /api/vaults/:id/secrets` — returns `[{key, inserted_at}]`. **Never returns plaintext values.**
- `POST /api/vaults/:id/secrets` — body: `{key, value}`. Value is encrypted with the tenant's data key before storage.
- `DELETE /api/vaults/:id/secrets/:key`.
- No `GET /api/vaults/:id/secrets/:key` or any endpoint that returns a plaintext secret value. The API contract must enforce this at the router level, not just by convention.

---

## 4. Conversation + Log Viewer

**Goal:** A user starts a Conversation, watches real-time log output stream in-browser, sends follow-up turns, and terminates the Conversation.

### Start Conversation

1. **Conversations list** (`/conversations`)
   - Table columns: Agent name, Status (badge), Started, Last turn (relative time), Actions (View, Terminate).
   - Status badge values and colors: `pending` (grey), `starting` (blue), `ready` (green), `terminated` (neutral), `failed` (red).
   - "New Conversation" button → `/conversations/new`.
   - Terminate from list: inline action — opens confirmation modal without navigating to the show page.
   - Pagination: server-side, 25 per page, newest first.

2. **New Conversation form** (`/conversations/new`)
   - Fields:
     - **Agent** (required): dropdown of tenant's agents, sorted by most recently used.
     - **Vault** (optional): dropdown — `— No vault —` + tenant vaults by name.
     - **Prompt** (required): textarea.
   - "Start" → `POST /api/conversations` with `{agent_id, vault_id?, prompt}`. Response: `{id, status: "pending", ...}`.
   - Redirect immediately to `/conversations/:id`. The conversation page takes over status tracking.
   - Validation: Agent required, Prompt required.

### Conversation show + log viewer

3. **Conversation show** (`/conversations/:id`)

   **Header bar**
   - Agent name (links to agent edit), Vault name (if set), Status badge (live-updating).
   - "Terminate" button: enabled when status is not `terminated` or `failed`. Opens confirmation modal.

   **Log stream panel** (main content area)
   - Displays LogEvents in arrival order. Two event types rendered differently:
     - `output` events: monospace text block, line by line. `stdout` in default colour; `stderr` in muted red or prefixed with a `stderr:` label.
     - `stage` events: inline lifecycle marker in a distinct style (lighter text, bracketed) — e.g. `[provisioning sandbox]`, `[setup script running]`, `[turn 1 started]`, `[turn 1 complete — exit 0]`, `[terminated]`.
   - **Auto-scroll**: panel scrolls to the bottom as new events arrive. If the user scrolls up, auto-scroll pauses. A "Jump to bottom" button appears; clicking it re-enables auto-scroll.
   - **SSE / PubSub subscription**: on LiveView mount, subscribe to PubSub topic `"conv:<tenant_id>:<conversation_id>"`. Replay missed events using the last received LogEvent integer PK as the resume cursor. New events pushed to the LiveView socket are appended to the panel in real time.
   - **Connection status indicator**: small persistent badge — "Live" (green), "Reconnecting" (yellow), "Disconnected" (red + manual "Reconnect" button).
   - **Empty state**: spinner + "Waiting for first output..." shown until the first LogEvent arrives.

   **Follow-up input** (pinned at bottom of log panel)
   - Visible when conversation status is `ready` or `running`.
   - Enabled only when status is `ready` and no Turn is actively running (i.e., the most recent Turn has an exit code).
   - Disabled with tooltip when status is `pending` or `starting` ("Sandbox is still starting...").
   - Hidden after status is `terminated` or `failed`.
   - Textarea + "Send" button.
   - On submit: `POST /api/conversations/:id/prompts` with `{prompt}`. New LogEvents arrive via the existing subscription.

   **Turn history sidebar** (collapsible, collapsed by default on narrow viewports)
   - Lists Turns: Turn number, prompt excerpt (first 80 chars), exit code, duration.
   - Clicking a Turn scrolls the log panel to the first LogEvent belonging to that turn.

4. **Terminate Conversation**
   - Confirmation modal: "Terminate this conversation? The sandbox will be destroyed. Log history is preserved."
   - `POST /api/conversations/:id/terminate`. Status → `terminated`. Follow-up input hidden. Log panel shows a `[terminated]` stage event.

5. **Error and edge states**
   - Status `failed`: banner — "This conversation failed to start. Check the log for details." Follow-up input hidden.
   - Status `starting` / `pending`: follow-up input disabled; log panel shows `[provisioning sandbox]` stage event.
   - SSE reconnection: LiveView reconnects automatically. On reconnect, the last received LogEvent PK is used as the resume cursor so no events are missed or duplicated.

### Engineering requirements

- `POST /api/conversations` — body: `{agent_id, vault_id?, prompt}`. Returns conversation with initial `status: "pending"`.
- `GET /api/conversations/:id/stream` — SSE endpoint. **Tenant ownership check required before opening the subscription.** Replays all events with `id >= Last-Event-ID` (or all events if header absent). Event wire format:
  ```
  id: <integer_pk>
  event: log_event
  data: {"kind":"output"|"stage","stream":"stdout"|"stderr"|null,"content":"...","inserted_at":"..."}
  ```
- `POST /api/conversations/:id/prompts` — body: `{prompt}`. Returns turn record. New LogEvents broadcast via PubSub.
- `POST /api/conversations/:id/terminate` — destroys sandbox, transitions status to `terminated`.
- `GET /api/conversations/:id/turns` — paginated, returns `[{id, number, prompt_excerpt, exit_code, started_at, ended_at}]` for the sidebar.
- **PubSub topic convention**: `"conv:<tenant_id>:<conversation_id>"` — tenant-namespaced to prevent cross-tenant subscription in a shared PubSub bus.
- **`log_events.id` must be a serial integer** (not UUID). The integer PK is the SSE replay cursor; ordering by PK is the canonical event order within a conversation.
- Recommend adding `status: "running"` as a transient sandbox state (set when a Turn starts, cleared when it exits) so the UI can disable the follow-up input without querying the turns table.

---

## 5. Account / Settings

**Goal:** A user manages their API keys, reviews usage, and understands their plan/billing status.

### 5a. API Key Management (`/settings/api-keys`)

1. **API keys list**
   - Table columns: Key name, Prefix (e.g. `ftn_live_ab12cdef...`), Created, Last used, Actions (Revoke).
   - "Create API key" button.
   - Empty state: "No API keys yet. Create one to use the REST API or CLI."

2. **Create API key**
   - Modal with a Name field (required, e.g. "CI pipeline", "Local dev").
   - On submit: `POST /api/auth/api-keys`. Response: `{id, name, key, created_at}` — the full key is returned **once only**.
   - Modal transitions to a "Copy your key" state: full key in a read-only input + copy button + warning: "This key will not be shown again. Copy it now before closing."
   - After the modal is dismissed, only the prefix appears in the list.

3. **Revoke API key**
   - Confirmation modal: "Revoke key <name>? Any integrations using this key will stop working immediately."
   - `DELETE /api/auth/api-keys/:id`.

### 5b. Usage Summary (`/settings/usage`)

1. **Usage panel**
   - Shows the current billing period (start → end dates).
   - Metrics for the period:
     - Conversations started
     - Turns executed
     - Sandbox-minutes consumed
     - LogEvent volume (approximate)
   - Summary table (or bar chart) of usage by day within the current period.
   - Link to `/conversations` for drilldown — no per-conversation breakdown required on this page at launch.

2. **State variants**
   - No usage: "No usage recorded for this period."
   - Near plan limit (e.g. ≥ 80% of sandbox-minutes): inline warning banner — "You've used 80% of your sandbox-minutes this month. Consider upgrading your plan."

### 5c. Plan / Billing Status (`/settings/billing`)

1. **Plan card**
   - Current plan name (e.g. "Free", "Pro").
   - Included limits (concurrent sandboxes, sandbox-minutes/month, etc.).
   - Renewal date or "No expiry" for free tier.
   - "Upgrade" button — at launch, this links to a waitlist form or contact page (billing is a stub per decisions/0003).

2. **Billing stub state**
   - `GET /api/billing/plan` returns a static response at launch.
   - When billing is live, the "Upgrade" button links to the Stripe Customer Portal.
   - The spec reserves `/settings/billing` as the route; the page content can be a placeholder at launch.

3. **Account danger zone** (bottom of `/settings/account`)
   - "Delete account": two-step confirmation — user must type `DELETE` to confirm. Destroys all tenant resources (environments, vaults, agents, conversations, secrets).
   - Not enforced at pre-launch; the route is reserved and the UI element can be present but gated behind a feature flag.

### Engineering requirements

- `POST /api/auth/api-keys` — body: `{name}`. Returns `{id, name, key, created_at}`. Full key returned on creation only; stored as a hash.
- `GET /api/auth/api-keys` — returns `[{id, name, prefix, created_at, last_used_at}]`. No plaintext key values.
- `DELETE /api/auth/api-keys/:id`.
- **API key format**: prefixed — `ftn_live_<random_bytes_base64url>`. Prefix stored as plaintext for display; full key is hashed (bcrypt or HMAC-SHA256) before storage. Prefixed format enables secret scanning integrations.
- `GET /api/usage/summary?period=current` — returns `{period_start, period_end, conversations, turns, sandbox_minutes, log_event_count}`. Usage events must be emitted at: conversation creation, turn start/end, sandbox-minute increments (background job aggregation is fine), LogEvent writes.
- `GET /api/billing/plan` — returns `{plan_name, limits: {...}, renewal_date}`. Can be a hardcoded stub at launch.

---

## Engineering Load-Bearing Decisions

The following UX decisions have direct API or data model implications that engineering must honor. Changes to these require a design re-review.

| Decision | Implication |
|---|---|
| SSE replay cursor is the integer `log_events.id` PK | `log_events.id` must be a serial integer, not a UUID. PK ordering is the canonical event order within a conversation. |
| Secret values are write-only in the UI | The API must never return secret plaintext in any GET response — not for Environment Secrets, not for VaultSecrets. There is no "edit value" flow; only delete + re-add. |
| PubSub topic is `"conv:<tenant_id>:<conversation_id>"` | Tenant-namespaced to prevent a LiveView subscription from leaking into another tenant's log stream. |
| Email verify endpoint sets a session cookie, not just a redirect | The wizard steps must be immediately accessible post-verification without a separate login step. |
| API key format: `ftn_live_<random>` prefix | Enables GitHub secret scanning. The prefix is the only plaintext retained; the full key is hashed. |
| Follow-up input disabled when a Turn is in-flight | Requires a `running` transient sandbox status (or an equivalent signal from the turns table) so the UI can gate the input without a separate polling call. |
| Billing is a stub at launch | `GET /api/billing/plan` can return hardcoded data. Usage event emission should be wired regardless — the data is needed once billing is live. |

## Flexible — Not Load-Bearing for Engineering

The following are UX choices that do not constrain the API or data model. Visual treatment, copy, and component structure are open.

- Visual design, color scheme, component library selection.
- Whether the Turn history sidebar is always visible or collapsible.
- Whether usage metrics are a bar chart or a summary table.
- The exact copy of confirmation dialogs and empty states.
- Sidebar nav item order.
- Whether `/settings/*` routes are implemented as tabs on a single LiveView or as separate routes (spec uses separate routes for clarity; either works).
- Pagination strategy (cursor vs. offset) and page size.
