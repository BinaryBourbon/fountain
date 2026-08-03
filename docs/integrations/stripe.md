# Stripe

**Optional.** The subscription gate exists for the hosted service; billing is
off by default (`BILLING_ENABLED=false`), and that is the right setting for
most self-hosted instances — a gate with no checkout behind it is a lock with
no key. Set this up only if you run Fountain commercially.

## Provider side

1. **A product with a recurring price.** Its price ID (`price_…`) becomes
   `STRIPE_PRICE_ID`.
2. **An API key** (Developers → API keys) — `STRIPE_SECRET_KEY`.
3. **A webhook endpoint** pointed at `<PUBLIC_URL>/api/stripe/webhook`,
   subscribed to:
    - `checkout.session.completed`
    - `customer.subscription.created`
    - `customer.subscription.updated`
    - `customer.subscription.deleted`
    - `customer.subscription.trial_will_end`

    Its signing secret becomes `STRIPE_WEBHOOK_SECRET`.

Use test-mode keys and a test-mode price everywhere except a production
instance taking real money.

## Env vars

| Variable | Effect |
|---|---|
| `BILLING_ENABLED` | `false` by default; `true` enforces the subscription gate on conversations |
| `STRIPE_SECRET_KEY` | API key |
| `STRIPE_WEBHOOK_SECRET` | Verifies webhook signatures; a bad signature is rejected with a 400 |
| `STRIPE_PRICE_ID` | The price surfaced by Checkout. Unset with billing enabled, signups get a purely local 14-day trial and a logged warning — and Checkout is broken |

## Behavior worth knowing

- On email verification (or OAuth signup), Fountain creates the Stripe
  customer and opens a **14-day trial subscription** with no payment method;
  Stripe cancels it at trial end if none is added. Trial expiry is *also*
  checked against the local clock, so a missed webhook delays revenue rather
  than opening the gate.
- Webhook processing is idempotent (event IDs are claimed in a dedup table)
  and order-safe (stale events are ignored). Transient failures return a 500
  so Stripe redelivers.
- Comped accounts are never overwritten by Stripe events.

## Verify

The webhook endpoint's delivery log in the Stripe dashboard should show 2xx
responses; a fresh signup should show a `trialing` status on
`/account/billing` and in the admin panel.

To exercise the full trial lifecycle without waiting 14 days, use
[Stripe Test Clocks](https://docs.stripe.com/billing/testing/test-clocks):
a customer created under a test clock can have its clock advanced past the
trial-ending threshold (the reminder email enqueues) and past trial end (the
status flips and the gate refuses). The clock must be attached when the
customer is created, so this is a deliberate test-mode exercise rather than
something you bolt onto an existing signup.

## Release verification: `mix fountain.verify_lifecycle`

The Test Clock exercise above is automated as a repeatable command — run it
before releasing **any billing-touching change**:

```bash
STRIPE_SECRET_KEY=sk_test_... mix fountain.verify_lifecycle
```

It creates a scratch user and a Test Clock, then walks the whole lifecycle —
trial → T-3d warning email enqueued → expiry (gate refuses, trial-expired
email) → paid subscription with a test card (gate opens) → cancel at period
end (access retained, `cancel_at_period_end`/`current_period_end` synced) →
period end (gate refuses, cancellation email, flag cleared) → re-subscribe
(the return path) → failed renewal on an always-failing test card (real
dunning: `past_due`, gate refuses, payment-failed email) —
asserting the **Fountain-side** state at every step. Each fetched Stripe
state is fed through `Billing.sync_subscription/1`, exactly what the webhook
controller does after signature verification; webhook *delivery* needs a
public endpoint and stays out of scope. Cleanup (clock + scratch user) runs
even when a step fails.

Notes:

- **Test-mode key only** — live keys are refused outright. The CLI's key
  lives in `~/.config/stripe/config.toml` (`test_mode_api_key`) and expires
  every 90 days; an expired key fails the preflight with a `stripe login`
  hint rather than a misleading mid-run error.
- Runs against the dev database; the scratch user is deleted afterwards.
- Deliberately **not CI**: external, ~1–2 minutes of clock advances, needs a
  key. It is a release-check, run by a person (or an agent) with the result
  pasted into the PR that motivated it.
- `STRIPE_PRICE_ID` is honored when set; otherwise a throwaway test-mode
  product/price is created under the clock's lifetime.
