# 0006 — Hard Stripe billing gate at launch with a 14-day trial

**Status:** Accepted — 2026-05-09.

## Context

The Phase 2 engineering plan raised OQ-5b: ship a hard billing gate at launch (block users without an active subscription from creating sandboxes), or ship a usage-tracking stub and add the gate later? OQ-5a asked which payment provider; OQ-5c asked the usage period.

The case for a stub at launch was reduced sprint scope: skip Stripe integration, leave `BILLING_WEBHOOK_URL` empty, ship the rest. The case for a hard gate was that Fountain pays for tenants' sandbox usage on a shared Sprites account (ADR 0005), so every free user is a direct cost line on the Sprites bill. Without a gate, scaling users without scaling revenue is the default behavior of the system.

Two related calls fall out of "hard gate": choice of provider (Stripe — best Elixir tooling via `stripity_stripe`, fastest path to ship a Checkout flow) and how to avoid locking users out the moment a payment fails (a `past_due` window with read-only access).

## Decision

Fountain ships with a **hard Stripe billing gate** at launch, integrated via `stripity_stripe`. New users get a **14-day trial** that begins at registration; a Stripe Customer is created at email verification, and `users.subscription_status` is synced from Stripe webhooks (`trialing`, `active`, `past_due`, `canceled`).

Gate enforcement, via `Fountain.Billing.assert_active!(user)`:

- **Allowed when** `subscription_status in [:trialing, :active]`.
- **Allowed read-only when** `subscription_status == :past_due` — the user can view past conversations, list resources, update payment method, but cannot start new conversations or provision sandboxes. This window exists so a temporary card decline doesn't lock users out of their own data while they fix payment.
- **Blocked when** `subscription_status in [:canceled, nil]` — POST to write endpoints returns 402 Payment Required pointing at the upgrade URL; LiveViews flash + redirect to `/account/billing`.

Plan management uses Stripe Checkout (new subscriptions) and Stripe Customer Portal (existing subscriptions, payment method updates, cancellation). Webhook endpoint `POST /api/stripe/webhook` is signature-verified via `Stripe.Webhook.construct_event/3`.

Usage period (OQ-5c): **calendar month in the user's selected timezone** (default UTC). `BillingLive` aggregates `usage_events` for the current calendar month.

Pricing tier shape (Free / Pro / etc.) is **not** decided here — that's growth/marketing's call before launch. This ADR commits to the gate mechanism, not the price points.

## Consequences

- Sprint scope grows by the Stripe integration: customer creation flow, webhook endpoint, Checkout + Portal links, `assert_active!` enforcement at three call sites (`ConversationServer.init/1`, `POST /api/conversations`, `:require_active_subscription` LiveView hook). Recommend treating it as its own sprint or a clearly-scoped track within the auth/billing sprint.
- Revenue exists from day 14 of the first paying user. Without the gate, revenue would be zero until a future sprint added it; the runway implication of that gap was the dispositive argument.
- Users who registered, did the wizard, and never paid silently consume Sprites resources during the 14-day trial. Mitigation: trial users are still bound by the per-tenant concurrency cap (default 5, ADR 0005). If trial-period costs surprise on the Sprites bill, drop the trial cap separately from the paid cap.
- Pricing decisions become unblocking: growth/marketing must propose tier prices before launch, even if "Free tier = blocked after trial" is the simplest opening position. The ADR does not require multiple tiers; one paid tier + the trial is enough to ship.
- `past_due` UX must be tested explicitly — it's the most common churn-inducing state and the easiest to get wrong (false lockouts on transient declines, or true lockouts when the read-only window is too short).
- Stripe is now a launch-blocking dependency. If Stripe is down, no new subscriptions complete and webhooks queue. `stripity_stripe` and Stripe's own retry behavior on webhook delivery are the mitigations; document the behavior when webhooks are delayed (subscription state lags reality by minutes — acceptable).
- Provider lock-in is Stripe-shaped: switching providers later means re-implementing Customer Portal flows and remapping subscription states. Within the cost of doing business; the alternative (provider-neutral abstraction at launch) costs more than it saves.
- Reversal cost: low for the gate itself (changing `assert_active!` to always return `:ok` is one line). High for the Stripe integration if it has to be ripped out — but no realistic post-launch path requires that.

## Alternatives considered

- **Usage-tracking stub at launch, gate added in growth sprint.** Rejected: every free user is a direct Sprites cost. Adding the gate later means migrating users who never expected to pay, which is worse UX than charging from launch.
- **Soft warn at launch (track usage, surface warnings, no enforcement).** Rejected: same cost problem as the stub, plus a worse story for "we never said this was free." A hard gate with a generous trial is more honest.
- **Paddle or Lemon Squeezy as merchant-of-record (handles tax/VAT globally).** Rejected for launch: Stripe has materially better Elixir tooling and a faster path to a working Checkout flow. International tax compliance is a real concern but addressable post-launch (Stripe Tax, or a provider switch if Stripe Tax proves inadequate). Don't trade ship velocity for problems that don't exist yet.
- **Lifetime / one-time payment instead of subscription.** Rejected: incompatible with a per-conversation cost model where Fountain pays Sprites continuously. Subscription matches the cost shape.
