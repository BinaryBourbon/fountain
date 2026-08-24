# Launch plans and prices

<!-- "billing", "pricing" and "plan pricing" are Technical Names here: they
     name the product surface, the BILLING_ENABLED flag and the Stripe
     objects. STE exempts a Technical Name from the -ing rule, and the linter
     has no vocabulary hook for that rule, so the exemption is declared for
     the page. -->
<!-- vale STE.IngForms = NO -->

This guide shows you how to sell more than one plan. It applies only to a
commercial instance with `BILLING_ENABLED=true`. Read
[Start billing](billing.md) first.

## What a plan controls

A plan sets one number that Fountain enforces. That number is the count of
sandboxes a tenant can run at the same time.

| Plan | Concurrent sandboxes | Turn hours | Contact ceiling | Price |
|---|---|---|---|---|
| Solo | 2 | 40 | 1 | $29/mo |
| Team | 5 | 100 | 3 | $79/mo |
| Scale | 10 | 200 | 10 | $199/mo |
| Legacy | 5 | 100 | 3 | $29/mo |

Every plan carries the whole product. Only the cap differs. See
[ADR 0026](https://github.com/jhgaylor/fountain/blob/main/decisions/0026-plans-and-entitlements.md)
for why.

`Legacy` is the flat plan that these tiers replaced. Fountain never offers it
to a new customer. It exists so that the accounts which bought the old price
keep it, at Team capacity.

### A trial is never larger than a plan

A trial is not one of the plans above. It is its own plan, and an account gets
it for the first 14 days whatever tier the subscription names.

| Plan | Concurrent sandboxes | Turn hours | Contact ceiling | Price |
|---|---|---|---|---|
| Trial | 2 | 40 | 0 | free |

The trial matches Solo on capacity and hours. It stays below Team and Scale.
No trial is larger than a plan that a customer pays for, so a subscription is
never a downgrade. This is also why the customer portal ends the trial on a
plan change instead of continuing it.

A trial includes no teammate contacts. That is the only limit which separates
a trial from Solo. An inbox and a phone number cost money as soon as they
exist. A free trial that gives one away invites abuse.

The trial applies only where billing is on. On a self-hosted instance every
account carries the `trialing` status and none of these limits.

The contact ceiling bounds teammate email and phone contacts. It is an abuse
bound, not an allowance. Fountain charges for each contact separately.

### Turn hours measure work, not clock time

Each plan includes 20 turn hours for each concurrent sandbox. A turn hour is
one hour with a prompt in flight. An agent that waits for a person spends no
turn hours. Time on a self-hosted runner also spends none, because Fountain
pays nothing for that machine. Turn hours add up for each turn. Two
conversations that each run for an hour on one sandbox spend two turn hours,
on a sandbox that was busy for one.

Fountain reports these hours and enforces nothing. No request fails because a
tenant exceeds the included hours. The price of an overage is still an open
question. See
[issue 1016](https://github.com/BinaryBourbon/fountain/issues/1016) for the
current state.

The pricing page states this to a visitor, because a plan that lists 200 hours
and then says nothing reads as a hard stop. The two limits behave differently.
Fountain refuses the next start for a tenant at the concurrency cap. A tenant
over the hours continues, and pays no more.

Four surfaces show the number. The pricing page shows it to a visitor. The
billing page shows it to the tenant. The API reports it at
`GET /api/account/billing`. The admin page for one account shows it beside the
sandbox count.

### The billing period

Fountain measures the hours over the period that Stripe invoices. The
`users.current_period_start` column holds the start of that period, and
Fountain reads it from the subscription at every webhook.

An account without such a period gets the calendar month instead. Every
surface states which window it used, because a number measured over the wrong
window must say so. Three kinds of account have no period. A comped account
has none. A self-hosted account has none. An account that received no
subscription webhook since this column arrived has none yet.

Fountain fills the column for one such account at the next renewal. To fill it
for every account at once, run this task.

```bash
bin/fountain_server eval 'Fountain.Release.backfill_billing_periods(dry_run: true)'
bin/fountain_server eval 'Fountain.Release.backfill_billing_periods()'
```

The task makes one Stripe read for each account that needs one. It writes the
two period columns and nothing else. It is safe to run more than once.

Use `eval` for this task, and `rpc` for the verifier above. This task starts
its own database connection, and an `rpc` restarts the pool of a pod that
serves traffic.

### A downgrade does not stop work in progress

The cap applies when a sandbox starts. A tenant who moves to a smaller plan
keeps every sandbox that already runs. Fountain refuses the next one until the
count falls below the new cap.

This is deliberate. A downgrade must not destroy an agent mid-task. Tell a
tenant who downgrades that the new cap applies to their next conversation.

## Create the prices in Stripe

Create one recurring monthly price for each plan you want to sell. Use USD.
Use a licensed price, not a metered one.

Create a fourth price for the teammate contact add-on if you charge for
teammate email and phone. Make that price licensed and monthly as well.

Record the four price ids. Each one starts with `price_`.

## Set the variables

Set one variable for each plan. A plan with no price id stays off the pricing
table and off the plan picker. You can therefore release the plans one at a
time.

```bash
STRIPE_PRICE_ID_SOLO=price_...
STRIPE_PRICE_ID_TEAM=price_...
STRIPE_PRICE_ID_SCALE=price_...
STRIPE_PRICE_ID_CONTACT=price_...
```

Keep `STRIPE_PRICE_ID` at its current value. It names the old flat price, and
the accounts on the `legacy` plan still point at it. Remove it only after the
last legacy account moves to a public plan.

Restart the instance to apply the variables.

## Verify the prices

The catalog holds a display price for each plan. Stripe holds the price that
the customer pays. Nothing links the two, so a wrong variable shows one number
and charges another.

Run the verifier against the same key the instance uses.

```bash
bin/fountain_server rpc 'Mix.Tasks.Fountain.VerifyPlans.run([])'
```

Use `rpc`, not `eval`. An `eval` starts a second copy of the code with no
application running, so it reads none of the configuration you want to check.

From a checkout, run `mix fountain.verify_plans` instead. The task reads each
price from Stripe. It fails if the amount, the currency, the interval or the
active flag disagrees with the catalog. The task changes nothing, so it is
safe against live mode.

Run it again after every price change.

## Check the accounts you already have

The migration puts every account with a Stripe customer on the `legacy` plan.
Those accounts hold 5 concurrent sandboxes, the same number as the old default
cap. No account lost capacity at the changeover.

The migration also clears the per-account cap wherever it still held the old
default of 5. A cap that an operator set to another value survives as an
override. An override always beats the plan.

Open `/admin/users` and read the sandbox column. It shows the enforced cap. The
field beside it holds the override. Clear that field to hand the cap back to
the plan.

## Charge for teammate contacts

An AgentMail inbox and an AgentPhone number cost you money every month, for as
long as the teammate holds them. Fountain bills them per unit, on a second
item on the same subscription.

Set `STRIPE_PRICE_ID_CONTACT` to start that. Fountain then sets the quantity
of that item to the number of contacts the tenant holds. It computes the
quantity from the contact rows every time, so a failed call repairs itself at
the next provision or release.

Set `STRIPE_CONTACT_PRICE_CENTS` to the same amount, for display.

!!! warning "This is a customer-facing change"

    A tenant who has teammate contacts today pays nothing for them. A line
    item appears on their next invoice once you set this variable. Tell them
    first.

## Give someone free numbers

Two levers, and they answer different questions.

To make an account pay **nothing at all**, comp the account. Open `/admin/users` and
select `comp` on the row. Fountain cancels the Stripe subscriptions and stops
all charges, contacts included. The teammate keeps the inbox and the number.

To let an account **pay for its plan and still hold a free number**, set the
comped contact count. Open `/admin/users`, put a number in the field beside the plan,
then select `free`. Fountain bills for the contacts above that count, and for
none if the count covers them all.

The second lever is the one for a staff account, a partner, or a customer you
gave a number to as an apology. The first makes their plan free as well, which
is more than you usually want.

## Reverse the change

Unset the three plan variables. Every account keeps the plan slug it holds,
and `Fountain.Plans` keeps enforcing that plan's cap. The pricing table and
the plan picker go away, because no public plan has a price.

To move one account, open `/admin/users` and set an override on it.

## Related

- [Start billing](billing.md).
- [Stripe integration guide](../../integrations/stripe.md).
- [Configuration reference](../../configuration.md).
- [See what sandboxes cost](sandbox-spend.md).

<!-- vale STE.IngForms = YES -->
