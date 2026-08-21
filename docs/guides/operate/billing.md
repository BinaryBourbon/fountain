# Turn on billing

This guide shows you how to enable the subscription gate, and why you probably
should not.

## Leave it off unless you are running Fountain commercially

Billing is off by default (`BILLING_ENABLED=false`), and the compose file also
pins it off.

The subscription gate exists for the hosted service. On your own instance it is
a lock with no key. Leave it off unless you are running Fountain commercially
and have configured Stripe.

With billing disabled, accounts carry no subscription status and no trial
clock. Nothing billing-shaped appears in the UI, the admin panel, or the API.

## Enable it

Set `BILLING_ENABLED=true` and configure Stripe. The
[Stripe integration guide](../../integrations/stripe.md) covers
`STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_ID` and the
provider-side setup.

## Start the clocks on existing accounts

Accounts created while billing was off have no trial to measure, and they
**fail closed** at the subscription gate the moment you enable it. Start their
trial clocks explicitly.

```bash
# See who would be affected, change nothing:
bin/fountain_server eval 'Fountain.Release.expire_legacy_trials(dry_run: true)'

# Mark them trialing with 14 days from now:
bin/fountain_server eval 'Fountain.Release.expire_legacy_trials(days: 14)'
```

Run the dry run first. It reports without changing anything.

## Verify it worked

Sign in as a non-admin account and confirm it can still reach a gated action.
An account that is locked out here is one the backfill missed.

## Related

- [Stripe integration guide](../../integrations/stripe.md).
- [Run a release task](run-a-release-task.md).
