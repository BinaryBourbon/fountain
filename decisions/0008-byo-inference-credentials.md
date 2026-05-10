# 0008 — BYO inference credentials per tenant

**Status:** Accepted — 2026-05-10.

## Context

Sandboxed agents need to authenticate to inference providers (Anthropic, OpenAI, Google). Up through PR #24, the four credentials Fountain knew about — `ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`, `OPENAI_API_KEY`, `GEMINI_API_KEY` — lived as platform-level env vars and were injected into every tenant's sandbox by the runtime modules (`Fountain.Runtimes.{Claude,Codex,Gemini,OpenCode}`). aod-ex (ADR 0002) does the same; it's single-tenant, so a single platform key is fine.

For Fountain, this raises three problems that the parallel decision for Sprites (ADR 0005) does not:

1. **Cost scales linearly with WAU and is unpredictable per tenant.** Inference is the dominant cost line for any agent product. Sprites usage is fungible (one sandbox is roughly one sandbox); a turn against Claude Opus is 100× the cost of a turn against Haiku, and tenants choose which model their agents use. Fountain can't price predictably if it pays the inference bill.
2. **Tenants want to bring their own Claude Pro/Team subscriptions.** `CLAUDE_CODE_OAUTH_TOKEN` exists specifically so users can bill against their own Claude.ai subscription instead of metered API. Forcing platform-shared credentials denies that. For many users it's the *only* economically viable way to run lots of agent turns.
3. **No isolation argument carries over from Sprites.** The ADR-0005 trust model was: "Sprites isolates sandboxes; Fountain wraps it." There's no equivalent isolation primitive for inference. If Fountain holds a single `ANTHROPIC_API_KEY` and proxies it, every tenant's traffic is auditable to one Fountain identity at the provider — bad for tenants who want their own usage attribution and bad for Fountain (legal exposure for what tenants do with the key).

## Decision

Fountain **does not** hold platform-level inference credentials. Each tenant supplies their own tokens for the providers they want to use.

Concretely:

- New `inference_credentials` table, one row per user, with four nullable ciphertext columns (`anthropic_api_key_ciphertext`, `claude_code_oauth_token_ciphertext`, `openai_api_key_ciphertext`, `gemini_api_key_ciphertext`). Each ciphertext is encrypted with the user's per-tenant DEK (`Fountain.Crypto`).
- New context module `Fountain.InferenceCredentials` handles get/put/decrypt. Plaintext is never stored or logged.
- New validator `Fountain.InferenceCredentials.Validator` pings each provider on save (cheap auth-only call) so users find typos / revoked keys at the boundary instead of mid-turn.
- `ConversationServer.handle_continue(:provision, ...)` loads the tenant DEK + decrypts inference credentials at conversation start; passes the decrypted map to `runtime_module.default_env(agent, credentials)`. Plaintext credentials live only in GenServer state for the conversation lifetime.
- Runtime modules (Claude, Codex, Gemini, OpenCode) updated to read from the passed-in credentials map; no `Application.get_env` reads for inference keys.
- Settings page at `/account/inference-credentials` lets users set/clear each credential.
- New required step at the start of the onboarding wizard: "Connect a provider." Without at least one credential set, the wizard does not advance. (User can still use the wizard-level "Skip wizard" link.)
- Platform env vars `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN` removed from `render.yaml`, `.env.example`, and `config/runtime.exs`.

## Consequences

- **Fountain pays $0 for inference.** Tenants pay their providers directly. This is a structural shift from ADR 0005's Sprites model and means inference cost is no longer a launch-economics concern.
- **Onboarding adds friction.** The first wizard step now blocks on "set at least one credential." Without a credential, agents can't run anyway, so blocking here is honest — but it raises the bar to a first conversation. The friction is mitigated by validate-on-save (immediate feedback) and accepting any one of four providers.
- **Cost attribution is per-tenant by construction.** The provider's invoice goes to the tenant; Fountain has nothing to reconcile. For metered pricing of Fountain itself, `usage_events` still records turn metadata (model, runtime) but not cost.
- **Plaintext lives in `ConversationServer` state for the conversation lifetime.** This is the same trust posture as the per-tenant DEK and tenant-encrypted vault secrets — process memory is the trust boundary. Credentials are dropped on `terminate/2` (best-effort in BEAM; rely on GC).
- **`Fountain.Crypto.load_tenant_key/1` is now load-bearing for inference.** Any user who can't unwrap their DEK (master-key rotation gone wrong, corrupted `user_data_keys` row) can't run conversations until the DEK is recoverable. The same risk already exists for vault/environment secrets; this raises the stakes.
- **Settings page is plaintext-on-input only.** The form shows "Set" / "Not set" but never echoes a stored credential back. Users who lose track of a key must re-paste it.
- **Validator makes a real network call on save.** ~200ms latency, no quota cost. If a provider is down at save time, save fails — accept this; the alternative (save without validation) defers the failure to the worst possible moment.

## Alternatives considered

- **Platform-shared credentials, like Sprites (ADR 0005).** Initially the implicit model — rejected because of the three problems in Context. Cost concentration alone would force this decision; isolation and Claude OAuth seal it.
- **Reuse the existing Vault primitive** — store the four credentials as `VaultSecret` rows in an auto-created "Inference" vault per user. Zero new schema. Rejected as convention-based ("the vault named X") and a poor fit for a fixed enumerated set with provider semantics. Validator wouldn't have a clean place to live, and the LiveView would need vault-name-string lookups everywhere.
- **Fields on `users` table.** Same data, no extra table. Rejected because it couples identity rows with secret blobs; `SELECT * FROM users` starts pulling encrypted ciphertext on every account read.
- **Optional onboarding step, with a banner on the dashboard** instead of a required step. Rejected after weighing — the first conversation will fail without a credential, and "set up a provider" is a more honest first-run task than "click Continue and discover the failure later."
- **Hybrid: Fountain keeps a fallback platform key, tenants override.** Rejected — the cost-attribution problem returns the moment any tenant doesn't override. Either tenants always pay or Fountain always pays; mixing produces neither benefit cleanly.
