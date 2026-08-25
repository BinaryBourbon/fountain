# Stripe

<!-- "billing" is a Technical Name here: the product surface, the
     CREDITS_ENABLED flag and the Elixir context carry it. STE exempts a
     Technical Name from Rule 3.4, and the linter has no vocabulary hook for
     that rule, so the exemption is declared for the page. -->
<!-- vale STE.IngForms = NO -->

**Optional.** Stripe is the till: it takes the payment for a credit pack and
tells Fountain about refunds and disputes. Nothing else. Billing is off by
default (`CREDITS_ENABLED=false`), and that is the right setting for most
self-hosted instances. Set this up only if you run Fountain commercially.

## At a glance

| | |
|---|---|
| Required | No, and off by default. |
| Provider | Stripe. |
| Env vars | `CREDITS_ENABLED`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` |
| Webhook | `<PUBLIC_URL>/api/stripe/webhook` |
| Without it | No way to buy credit. Admin grants still work. |

## The provider side

1. **An API key**, from Developers → API keys, as `STRIPE_SECRET_KEY`.
2. **A webhook endpoint** pointed at `<PUBLIC_URL>/api/stripe/webhook`,
   subscribed to these three events.
    - `checkout.session.completed`, which adds the credit a pack paid for.
    - `charge.refunded`, which removes the refunded amount.
    - `charge.dispute.created`, which removes the disputed amount.

    Its signing secret becomes `STRIPE_WEBHOOK_SECRET`.

You create no product and no price. Each pack is a one-time Checkout with the
amount in the session, from `CREDIT_PACKS_CENTS`.

Use test-mode keys everywhere, except on a production instance that takes
real money.

## Env vars

| Variable | Effect |
|---|---|
| `CREDITS_ENABLED` | `false` by default. `true` turns credits on. |
| `STRIPE_SECRET_KEY` | The API key. |
| `STRIPE_WEBHOOK_SECRET` | Verifies a webhook signature. Fountain rejects a bad signature with a 400. |

## Behavior worth knowing

- Fountain creates the Stripe customer at the first pack purchase, not at
  signup. An account that never buys is never a Stripe customer.
- Webhook processing is idempotent. Fountain claims each event ID in a dedup
  table, and adds a pack once however many times Stripe delivers the
  event. A transient failure returns a 500, so that Stripe delivers it again.
- A refund removes the refunded amount from the balance, and the balance can
  go below zero. A won dispute puts nothing back by itself. Add it by hand
  from the admin panel, or with `POST /api/admin/users/:id/credits`.
- A comped account cannot buy. It has nothing to pay for.

## Verify

The delivery log for the webhook endpoint in the Stripe dashboard must show
2xx responses. Buy the smallest pack with a test card, and the balance on
`/account/billing` rises by that amount when the webhook lands.

## Related

- [Start billing](../guides/operate/billing.md), the operator guide.
- [Prices](../guides/operate/plans-and-prices.md).
- [Services Fountain uses](index.md).

<!-- vale STE.IngForms = YES -->
