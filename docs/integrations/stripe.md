# Stripe

<!-- "billing" and "dunning" are Technical Names here: the product surface,
     the BILLING_ENABLED flag and the Elixir context carry the first, and the
     second is the industry term for the failed-payment sequence. STE exempts
     a Technical Name from Rule 3.4, and the linter has no vocabulary hook for
     that rule, so the exemption is declared for the page. -->
<!-- vale STE.IngForms = NO -->

**Optional.** The subscription gate exists for the hosted service. Billing is
off by default (`BILLING_ENABLED=false`), and that is the right setting for
most self-hosted instances. A gate with no checkout behind it is a lock with
no key. Set this up only if you run Fountain commercially.

## At a glance

| | |
|---|---|
| Required | No, and off by default. |
| Provider | Stripe. |
| Env vars | `BILLING_ENABLED`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_ID_SOLO`, `STRIPE_PRICE_ID_TEAM`, `STRIPE_PRICE_ID_SCALE` |
| Webhook | `<PUBLIC_URL>/api/stripe/webhook` |
| Without it | No billing, which is correct for most self-hosted instances. |

## The provider side

1. **A product with a recurring monthly price for each plan you sell.** The
   price IDs (`price_…`) become `STRIPE_PRICE_ID_SOLO`, `STRIPE_PRICE_ID_TEAM`
   and `STRIPE_PRICE_ID_SCALE`. See
   [Launch plans and prices](../guides/operate/plans-and-prices.md).
2. **An API key**, from Developers → API keys, as `STRIPE_SECRET_KEY`.
3. **A webhook endpoint** pointed at `<PUBLIC_URL>/api/stripe/webhook`,
   subscribed to these events.
    - `checkout.session.completed`
    - `customer.subscription.created`
    - `customer.subscription.updated`
    - `customer.subscription.deleted`
    - `customer.subscription.trial_will_end`
    - `invoice.payment_failed`
    - `invoice.payment_action_required`
    - `invoice.paid`

    Its signing secret becomes `STRIPE_WEBHOOK_SECRET`.

    An endpoint that already exists keeps working without the three
    `invoice.*` events. Dunning state still syncs from the subscription
    events. But the SCA email, the one that says "confirm your payment", never
    fires, and a recovery notice then depends on
    `customer.subscription.updated` alone. Add the three when you upgrade.

Use test-mode keys and a test-mode price everywhere, except on a production
instance that takes real money.

## Env vars

| Variable | Effect |
|---|---|
| `BILLING_ENABLED` | `false` by default. `true` enforces the subscription gate on conversations. |
| `STRIPE_SECRET_KEY` | The API key. |
| `STRIPE_WEBHOOK_SECRET` | Verifies a webhook signature. Fountain rejects a bad signature with a 400. |
| `STRIPE_PRICE_ID_SOLO` | The price for the Solo plan, and the price a trial opens on by default. Leave every plan price unset with billing on, and a signup gets a purely local 14-day trial, with a logged warning. Checkout then does not work. |
| `STRIPE_PRICE_ID_TEAM` | The price for the Team plan. |
| `STRIPE_PRICE_ID_SCALE` | The price for the Scale plan. |
| `STRIPE_PRICE_ID` | The flat price that the plans replaced. Accounts that bought it stay on the closed `legacy` plan. A new deployment does not need it. |

## Behavior worth knowing

- At email verification, or at an OAuth signup, Fountain creates the Stripe
  customer and opens a **14-day trial subscription** with no payment method.
  Stripe cancels that subscription at the end of the trial when nobody adds
  one. Fountain *also* checks trial expiry against the local clock, so a
  webhook that never arrives delays revenue. It does not open the gate.
- Webhook processing is idempotent. Fountain claims each event ID in a dedup
  table. It is also safe against order, because it ignores a stale event. A
  transient failure returns a 500, so that Stripe delivers it again.
- Fountain never overwrites a comped account from a Stripe event.
- `invoice.payment_failed` and `invoice.payment_action_required` drive the
  dunning and SCA emails. Neither one writes subscription status, which stays
  with the subscription events. `invoice.paid` writes status in exactly one
  case, `past_due → active`, which is a dunning recovery. Stripe also pays a
  $0 invoice at trial creation, and one at each normal renewal, and neither
  must touch the account.

## Verify

The delivery log for the webhook endpoint in the Stripe dashboard must show
2xx responses. A fresh signup must show a `trialing` status on
`/account/billing` and in the admin panel.

To exercise the full trial lifecycle without a 14-day wait, use
[Stripe Test Clocks](https://docs.stripe.com/billing/testing/test-clocks). A
customer created under a test clock can have its clock advanced past the
threshold that ends the trial, where the reminder email enqueues. Advance it
past the end of the trial, and the status flips and the gate refuses.

You must attach the clock when you create the customer. So this is a
deliberate test-mode exercise, and not something you bolt onto a signup that
already exists.

## Release verification: `mix fountain.verify_lifecycle`

One command automates the Test Clock exercise above, and you can repeat it.
Run it before you release **any change that touches billing**.

```bash
STRIPE_SECRET_KEY=sk_test_... mix fountain.verify_lifecycle
```

It creates a scratch user and a Test Clock, then walks the whole lifecycle. It
asserts the **Fountain-side** state at each step.

1. Trial.
2. The T-3d warning email enqueues.
3. Expiry. The gate refuses, and the trial-expired email goes out.
4. A paid subscription with a test card. The gate opens.
5. Cancel at period end. Access stays, and `cancel_at_period_end` and
   `current_period_end` sync.
6. Period end. The gate refuses, the cancellation email goes out, and the flag
   clears.
7. Re-subscribe, which is the return path.
8. A renewal that fails, on a test card that always fails. That is real
   dunning: `past_due`, the gate refuses, the payment-failed email goes out,
   and the real failed invoice feeds through `invoice.payment_failed`.
9. Dunning recovery. A card that works pays the open invoice, `invoice.paid`
   flips `past_due → active`, the gate opens, and the payment-recovered email
   goes out.

Each Stripe state it fetches goes through `Billing.sync_subscription/1`, which
is exactly what the webhook controller does after it verifies the signature.
Webhook *delivery* needs a public endpoint, and stays out of scope. The
cleanup, which is the clock and the scratch user, runs even when a step fails.

Four notes.

- **A test-mode key, and no other.** Fountain refuses a live key outright. The
  CLI's key lives in `~/.config/stripe/config.toml`, as `test_mode_api_key`,
  and it expires every 90 days. An expired key fails the preflight with a
  `stripe login` hint, and does not produce a confusing error mid-run.
- It runs against the dev database, and it deletes the scratch user
  afterwards.
- It is deliberately **not in CI**. It is external, it takes one to two
  minutes of clock advances, and it needs a key. It is a release check that a
  person, or an agent, runs. Paste the result into the PR that motivated it.
- It honors `STRIPE_PRICE_ID` when you set one. Otherwise it creates a
  throwaway test-mode product and price, which live as long as the clock.

## Related

- [Start billing](../guides/operate/billing.md), the operator guide, with the
  backfill that existing accounts need.
- [Services Fountain uses](index.md).

<!-- vale STE.IngForms = YES -->
