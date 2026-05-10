## Context

Auth is merged. `Fountain.Accounts` (User with `subscription_status`, `stripe_customer_id`), all auth plugs, and `on_mount :require_authenticated_user` are in `main`. The full billing spec is at `plan/phase-2-build-plan/engineering-plan.md` §5. ADR 0006 (`decisions/0006-stripe-billing-hard-gate-at-launch.md`) is the load-bearing decision. Read both before writing any code.

A parallel slice (`phase-3-onboarding-liveview`) is running at the same time. It owns `lib/fountain_web/live/onboarding_live.ex`, `log_viewer_live.ex`, `api_keys_live.ex`, `admin_live.ex`. You own `lib/fountain/billing.ex`, `lib/fountain_web/live/billing_live.ex`, `lib/fountain_web/controllers/stripe_webhook_controller.ex`, and the new router entries for billing routes. If both slices touch `router.ex`, add routes in clearly separated blocks to minimise conflicts.

## Task

Branch `phase-3-billing` from `main`.

- **`Fountain.Billing` context**:
  - `assert_active!(user)` — raises `Fountain.Billing.SubscriptionRequiredError` unless `subscription_status in [:trialing, :active]`. Call sites: `ConversationServer.init/1` and `POST /api/conversations` controller.
  - `create_stripe_customer(user)` — calls `Stripe.Customer.create/1`, stores the returned customer ID in `users.stripe_customer_id`. Called on email verification (after `email_verified_at` is set).
  - `sync_subscription(stripe_event)` — handles Stripe webhook events: `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`. Updates `users.subscription_status` and trial expiry from the event payload.
  - `usage_summary(user_id, period_start, period_end)` — aggregates `usage_events` for the period. Returns `%{conversations: n, turns: n, sandbox_minutes: n}`.
- **Migration**: add `stripe_customer_id string`, `subscription_status string default "trialing"`, `trial_ends_at utc_datetime`, `session_version integer default 0` to `users`. `subscription_status` is not nullable; `trialing` is the default for all new users.
- **`FountainWeb.StripeWebhookController`**: `POST /api/stripe/webhook` — verify signature with `Stripe.Webhook.construct_event/3` using `STRIPE_WEBHOOK_SECRET`. Dispatch to `Billing.sync_subscription/1`. Always return 200 to Stripe even on processing errors (log errors, don’t 500).
- **`FountainWeb.Live.BillingLive`** at `/account/billing` per UX spec §5b:
  - Subscription status card: plan name, `subscription_status` badge, trial countdown (days remaining if `trialing`, renewal date if `active`, warning if `past_due`).
  - Usage summary for current calendar month via `Billing.usage_summary/3`.
  - “Upgrade” button: if no Stripe subscription, link to `Stripe.Checkout.Session.create/1` (hosted Checkout). If subscription exists, link to `Stripe.BillingPortal.Session.create/1` (Customer Portal).
  - `past_due` banner: “Your subscription requires attention. Update your payment method to continue starting conversations.”
- **Hard gate in router**: add `on_mount :require_active_subscription` hook (in `FountainWeb.Live.Hooks`) that calls `Billing.assert_active!/1` and redirects to `/account/billing` on `SubscriptionRequiredError`. Apply this hook to conversation/sandbox LiveView routes only (not read-only routes: logs, resource lists, settings).
- **REST gate**: in `POST /api/conversations` controller, call `Billing.assert_active!(current_user)` before `Conversations.start_conversation/2`. Return HTTP 402 with body `{error: "subscription_required", upgrade_url: "/account/billing"}` on failure.
- **Trial provisioning**: in `EmailVerificationController`, after setting `email_verified_at`, call `Billing.create_stripe_customer(user)` (async via `Task.async`) and set `trial_ends_at = DateTime.utc_now() + 14 days`.

## Acceptance

- PR `phase-3-billing` against `main`.
- `mix compile` and `mix test` pass. Tests cover: `assert_active!` for all four statuses, webhook signature verification (use Stripe test keys), `usage_summary/3` aggregation, 402 response on expired trial.
- `POST /api/conversations` returns 402 when `subscription_status: :canceled`.
- Stripe webhook endpoint returns 200 on valid event and 400 on bad signature.
- `BillingLive` renders trial countdown correctly for a user with `trial_ends_at` in the future.

## Out of scope

- Do not implement onboarding wizard, log viewer, or API keys LiveView — that is `phase-3-onboarding-liveview`.
- Do not implement metered billing or multiple plan tiers — one Stripe product, one price is sufficient at launch.
- Do not implement the admin billing override UI — admins adjust quotas via `users.max_concurrent_sandboxes` directly; a billing override UI is post-launch.
