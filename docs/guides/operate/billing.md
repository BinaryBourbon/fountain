# Start billing

<!-- "billing" is a Technical Name here: the product surface, the
     BILLING_ENABLED flag and the Elixir context all carry it. STE exempts a
     Technical Name from the -ing rule, and the linter has no vocabulary
     hook for that rule, so the exemption is declared for the page. -->
<!-- vale STE.IngForms = NO -->

This guide shows you how to start the subscription gate, and why you probably
must not.

## Leave it off unless you run Fountain commercially

Billing is off by default (`BILLING_ENABLED=false`), and the compose file pins
it off as well.

The subscription gate exists for the hosted service. On your own instance it
is a lock with no key. Leave it off, unless you run Fountain commercially and
you configured Stripe.

With billing off, an account carries no subscription status and no trial
clock. Nothing that looks like billing appears in the UI, in the admin panel
or in the API.

## Start it

Set `BILLING_ENABLED=true`, then configure Stripe. The
[Stripe integration guide](../../integrations/stripe.md) covers
`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET` and the provider side.

Then choose what you sell. [Launch plans and prices](plans-and-prices.md)
covers the three tiers and the price variable for each one. It also covers the
verifier that finds a price which disagrees with the catalog.

## Start the clocks on the accounts you already have

An account created while billing was off has no trial to measure. It **fails
closed** at the subscription gate the moment you turn billing on. Start those
trial clocks explicitly.

```bash
# See who would be affected, change nothing:
bin/fountain_server eval 'Fountain.Release.expire_legacy_trials(dry_run: true)'

# Mark them trialing with 14 days from now:
bin/fountain_server eval 'Fountain.Release.expire_legacy_trials(days: 14)'
```

Run the dry run first. It reports, and it changes nothing.

## Start prepaid credits

Credits are off until you set `CREDIT_PRICING_SINCE`. Do these steps in
this order, because each one protects the next.

1. Set `CREDIT_PRICING_SINCE` to the time of the deploy, in ISO 8601. Do
   not set an earlier time. An earlier time bills every tenant for turns
   they ran before they held a grant.
2. Deploy. From that instant, Fountain prices turns into the ledger and
   shows the balance on the billing page. Fountain refuses nothing.
3. Give every tenant their opening credit, so nobody starts at zero.

   ```bash
   # See who would be granted, change nothing:
   bin/fountain_server eval 'Fountain.Release.start_credits(dry_run: true)'

   # Grant the current period, pro-rated from CREDIT_PRICING_SINCE:
   bin/fountain_server eval 'Fountain.Release.start_credits()'
   ```

   Run the dry run first. A rerun of the real task writes nothing new.
4. Add `charge.refunded` and `charge.dispute.created` to your Stripe webhook
   endpoint, so a refund takes the credit back.
5. After a month of provider invoices reconciled on `/admin/finance`, set
   `CREDIT_ENFORCE=true`. From then, a zero balance refuses new sandboxes and
   new turns.

[Launch plans and prices](plans-and-prices.md) covers the prices and the
packs.

## Verify it worked

Sign in as an account that is not an admin, then confirm it can still reach a
gated action. An account that cannot is one the backfill missed.

## Related

- [Stripe integration guide](../../integrations/stripe.md).
- [Launch plans and prices](plans-and-prices.md).
- [See what sandboxes cost](sandbox-spend.md), for what each account runs and
  which provider you pay for it.
- [Run a release task](run-a-release-task.md).

<!-- vale STE.IngForms = YES -->
