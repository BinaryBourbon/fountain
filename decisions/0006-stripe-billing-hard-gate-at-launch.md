# 0006 — Hard Stripe billing gate at launch with 14-day trial

**Status:** Accepted — 2026-05-10.

## Context

Fountain is a hosted platform with real operating costs (Sprites sandboxes per conversation, managed Postgres, Render). A billing stub (emit usage events, charge nothing) is operationally simpler but creates an unbounded cost exposure at launch and makes the transition to paid billing a high-friction event for existing users.

## Decision

Fountain enforces a **hard Stripe billing gate at launch**:

- Billing provider: **Stripe** via `stripity_stripe`.
- Users get a **14-day trial** (`subscription_status: :trialing`) on registration. No credit card required to start the trial.
- When the trial expires, `subscription_status` transitions to `past_due` (or `canceled` if no payment method added). New conversations are blocked.
- **Hard gate:** `Fountain.Billing.assert_active!(user)` is called in `ConversationServer.init/1` and in `POST /api/conversations`. A non-active subscription raises `Fountain.Billing.SubscriptionRequiredError`, returned as HTTP 402 with a body pointing at the upgrade URL.
- **Read-only access preserved during `past_due`:** users can still view past logs, list resources, and update payment details. Only new sandbox provisioning is blocked.
- A Stripe Customer record is created on user verification (not at payment). This ensures the Stripe Customer exists before the trial ends, avoiding a race at upgrade time.
- Stripe webhooks (`POST /api/stripe/webhook`, signature-verified) keep `users.subscription_status` in sync.
- Usage events (`turn_started`, `sandbox_provisioned`, `sandbox_terminated`) are emitted to `usage_events` regardless of billing status — the data is needed for metering once paid plans are active.

## Consequences

- Requires `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, and `STRIPE_WEBHOOK_SECRET` to be set in the Render environment before any user can complete onboarding.
- A Stripe product and at least one price must be created in the Stripe dashboard before launch (pricing TBD by the operator; the engineering implementation is price-agnostic).
- 14-day trial is generous enough that onboarding users are unlikely to hit the gate before they’ve evaluated the product.
- If pricing strategy changes, the trial duration and plan structure are operator-controlled via the Stripe dashboard; no code changes are required.

## Alternatives considered

- **Billing stub at launch (emit events, charge nothing)** — Rejected. Unbounded cost exposure; harder to transition existing free users to paid billing post-launch than to start paid from day one with a generous trial.
- **Metered billing (pay-per-turn)** — Deferred. Flat subscription is simpler to implement and reason about at launch. Metered billing can be added as a plan tier once usage patterns are understood.
