# Fountain Scope Comparison — Phase 0 Framing

## Background

Fountain rebuilds `jhgaylor/aod-ex` — a single-tenant REST API for spawning AI coding agents inside sandboxed Sprites — for multi-tenant, external-user deployment. This document frames two candidate scopes for the G0 gate decision. It does not recommend a direction.

**Success target:** 100 weekly active users by month 6.

---

## What aod-ex provides today

aod-ex manages the following primitives for a single operator:

| Primitive | What it is |
|---|---|
| **Environment** | Packages, env vars, networking rules, repos, setup script. Owns baseline encrypted Secrets (AES-256-GCM). |
| **Secret** | Encrypted key-value pairs owned by an Environment. Baseline credential set for all conversations in that environment. |
| **Vault** | Free-floating bag of encrypted env-var overrides. Selected per-conversation; vault values win over environment secrets on collision. Used to swap credentials (GitHub identity, API key) without redefining the environment. |
| **Agent** | Name, system prompt, model, runtime (claude/codex/gemini), optional Environment, optional MCP servers, optional Skills. |
| **Skill** | Inline (`{name, content}`) or GitHub-sourced (`{source, name?}`) SKILL.md fragments mounted into the sprite before the first turn. A built-in `aod` callback skill is always prepended. |
| **Sandbox** | One running Sprite. Lifecycle: `pending → starting → ready → terminated\|failed`. |
| **Conversation** | One chat session: one Agent, one Sandbox, optional Vault. Has many Turns. Multi-turn via claude `--resume` using a persisted `runtime_session_id`. |
| **Turn** | One prompt → exit_code cycle inside a Conversation. |
| **LogEvent** | Stdout/stderr lines and lifecycle markers from the runtime CLI. Integer PK enables SSE replay via `Last-Event-ID`. |

**Three surfaces:** API (JSON/HTTP, bearer-token auth), UI (Phoenix LiveView, same token via login page), CLI (`./aod`, reads `AOD_BASE_URL` + `AOD_TOKEN`).

**Auth model:** Single `ADMIN_TOKEN` shared by the operator. All resources are global to that instance.

**Deployment:** One-command deploy to a Sprite (`aod up`) or Render. SQLite on a persistent disk. Single `SECRETS_KEY` encrypts all secrets.

---

## The multi-tenancy gap

The table below shows what must change or be added when multiple external users share a single Fountain instance:

| Dimension | aod-ex (single-tenant) | Fountain (multi-tenant) |
|---|---|---|
| **Auth** | One `ADMIN_TOKEN` for everything | Per-user identity: sign-up, credential issuance (API keys or OAuth), session management |
| **Resource isolation** | All Environments, Vaults, Agents, Conversations are global | Every resource scoped to an owner (user or org); cross-tenant reads must be impossible |
| **Secret isolation** | Single `SECRETS_KEY` encrypts all secrets | Per-tenant key material or envelope encryption; a compromised tenant must not expose others |
| **Sandbox quotas** | No limits; operator controls single `SPRITES_TOKEN` | Per-tenant concurrency limits, runtime caps, and Sprites token pooling or delegation |
| **Billing surface** | None | Usage events (Turns, Sandbox-minutes, LogEvent volume) attached to a tenant; billing hooks or subscription gates |
| **Onboarding UX** | Operator manually sets env vars and runs `aod up` | External user must be able to arrive at a URL, register, configure a first agent, and start a conversation without operator involvement |
| **Debugging affordances** | Operator has full DB and log access | User sees only their own LogEvents and Conversations; support/admin needs scoped read access without cross-tenant exposure |
| **Callback skill routing** | Single `AOD_PUBLIC_URL` routes all `aod` skill callbacks to one instance | Callbacks must route to the correct tenant's context, or carry a tenant-scoped token |

---

## Scope Option A — API-Only Multi-Tenant Core

### Premise

Ship the minimum surface that makes aod-ex safe and usable for multiple external users. No hosted UI or CLI. Users integrate directly against the API.

### aod-ex primitives: kept as-is

Environment, Secret, Vault, Agent, Skill, Sandbox, Conversation, Turn, LogEvent — all concepts preserved, all API endpoints rebuilt with tenant scoping.

### aod-ex primitives: changed

| Primitive | Change |
|---|---|
| **Environment / Vault / Agent / Conversation** | Add `tenant_id` foreign key; all list/read/write endpoints filter by authenticated tenant |
| **Secret** | Envelope encryption: per-tenant data key wrapped by a master key or KMS; the single shared `SECRETS_KEY` is replaced |
| **Sandbox** | Quota enforcement per tenant; Sprites token pooled or delegated so one tenant cannot exhaust capacity for others |
| **LogEvent** | SSE stream gated by tenant ownership check before the subscription is opened |

### Multi-tenancy additions required

- **Users / API Keys table**: sign-up, API key issuance, key revocation
- **Usage events table**: Turn-started, Sandbox-provisioned, LogEvent-written — emitted for billing and metering
- **Billing hook**: webhook or integration point for a payment provider to gate access (can be a stub at launch)
- **Admin scoped read**: support role that can read any tenant's data for debugging without owning it

### Surfaces

API only. The UI and CLI surfaces are explicitly deferred; users write their own clients or use curl/Postman.

### Tradeoffs

| Pro | Con |
|---|---|
| Faster to ship — no UI build, no LiveView multi-tenant refactor, no CLI distribution | Lower onboarding rate — external users must write code or use curl; 100 WAU in 6 months requires developer-grade early adopters |
| API contract can be validated cheaply before committing to a UI | No visual surface makes sales and marketing harder; Swagger UI at `/api/docs` is the only interactive affordance |
| Smaller attack surface while product-market fit is unknown | Debugging is entirely self-service — users tail their own SSE streams with no in-product log viewer |

---

## Scope Option B — API + Hosted UI with Self-Serve Onboarding

### Premise

Rebuild all three aod-ex surfaces for multi-tenant use. External users can sign up at a URL, configure agents through a dashboard, and start conversations without touching the API directly.

### aod-ex primitives: kept as-is

All Option A API changes, plus the UI and CLI surfaces are carried forward and adapted for multi-tenant use.

### aod-ex primitives: changed

Everything in Option A, plus:

| Primitive | Change |
|---|---|
| **UI (Phoenix LiveView)** | Login page replaced by self-serve sign-up and auth flow; all LiveView resources scoped to the authenticated user; no global admin view for regular users |
| **CLI** | Distributed as a preconfigured binary pointing at the hosted service; `AOD_BASE_URL` defaults to Fountain's domain; auth via API key rather than `ADMIN_TOKEN` |
| **`aod` callback skill** | `AOD_PUBLIC_URL` becomes a tenant-namespaced route or carries a tenant token so callbacks land in the correct tenant's context |

### Multi-tenancy additions required

All of Option A, plus:

- **Onboarding flow**: sign-up → email verification → first-agent wizard → first conversation — walkable in the UI without reading documentation
- **Dashboard**: per-tenant view of Conversations (status, Turns, LogEvents), Agents, Environments, Vaults
- **Log viewer**: in-browser SSE replay for a conversation's LogEvents (replaces the operator's `curl -N` workflow)
- **Team / org layer** *(optional for launch)*: invite teammates, shared Environments and Agents within an org, role-based access (admin/member)
- **Billing UI**: subscription plan display, usage summary, upgrade/downgrade flow
- **Support tooling**: admin view across tenants for Sandbox debugging without cross-tenant data exposure

### Surfaces

API + UI + CLI — matching aod-ex's three-surface principle, each rebuilt for multi-tenant use.

### Tradeoffs

| Pro | Con |
|---|---|
| Higher onboarding rate — non-developer users can self-serve; visual demos are possible; lowers the bar to 100 WAU | Slower to ship — UI multi-tenant refactor is significant; onboarding flow, billing UI, and log viewer add material scope |
| Clearer path to the 6-month success metric — 100 WAU is harder to achieve from an API-only product without a growth loop | More surface area exposed early = more potential failure points before product-market fit is confirmed |
| Enables sales and marketing with a live demo | Higher engineering cost — requires design, frontend work, and auth UX in addition to backend multi-tenancy |

---

## Side-by-Side Summary

| | Option A: API-Only Core | Option B: API + UI + Onboarding |
|---|---|---|
| **aod-ex primitives preserved** | All (API surface only) | All (all three surfaces) |
| **aod-ex primitives changed** | Resource scoping, secret encryption, sandbox quotas, SSE auth | Same + LiveView auth, CLI distribution, callback skill routing |
| **Multi-tenancy additions** | Users/API keys, usage events, billing hook, admin read | Same + onboarding flow, dashboard, log viewer, billing UI, support tooling |
| **Auth** | API key per user | API key + session cookie (UI) |
| **Resource isolation** | Tenant-scoped DB queries | Same |
| **Billing surface** | Usage event emission + webhook stub | Same + in-product subscription UI |
| **Onboarding UX** | Developer self-service via API docs | Guided wizard in product |
| **Debugging affordances** | SSE stream via API | In-browser log viewer |
| **Time to first external user** | Shorter | Longer |
| **Path to 100 WAU in 6 months** | Requires developer-grade TAM | Opens to broader TAM |

---

## Open questions for the G0 gate

The following are not answered by this document and require the human operator's decision:

1. **Which scope?** Option A (API-only, faster, narrower TAM) or Option B (full surfaces, slower, broader TAM)?
2. **Target user at launch**: developer integrating Fountain into their own tooling (favors A) vs. non-developer who needs a UI to configure and run agents (favors B)?
3. **Team capacity**: does the team have bandwidth for UI/UX work in the first sprint, or should that be deferred to a later phase?
4. **Billing gate at launch**: is billing enforcement required at day one, or can it be a usage-tracking stub while the product is validated?
5. **Org/team features**: are shared Environments and Agents within a team in scope for launch (Option B only), or is solo-user multi-tenancy sufficient?

---

*Document produced by the customer-researcher role per the Phase 0 brief. No direction is recommended here — the G0 call belongs to the human operator.*
