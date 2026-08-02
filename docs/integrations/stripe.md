# Stripe

**Optional.** The subscription gate exists for the hosted service; the compose
file ships `BILLING_ENABLED=false`, and that is the right setting for most
self-hosted instances — a gate with no checkout behind it is a lock with no
key. Set this up only if you run Fountain commercially.

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
| `BILLING_ENABLED` | `true` (the default) enforces the subscription gate on conversations |
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
