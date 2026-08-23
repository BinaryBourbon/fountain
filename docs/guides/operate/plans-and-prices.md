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

| Plan | Concurrent sandboxes | Contact ceiling | Price |
|---|---|---|---|
| Solo | 5 | 1 | $29/mo |
| Team | 15 | 3 | $79/mo |
| Scale | 40 | 10 | $199/mo |
| Legacy | 15 | 3 | $29/mo |

Every plan carries the whole product. Only the cap differs. See
[ADR 0026](https://github.com/jhgaylor/fountain/blob/main/decisions/0026-plans-and-entitlements.md)
for why.

`Legacy` is the flat plan that these tiers replaced. Fountain never offers it
to a new customer. It exists so that the accounts which bought the old price
keep it, at Team capacity.

The contact ceiling bounds teammate email and phone contacts. It is an abuse
bound, not an allowance. Fountain charges for each contact separately.

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
Those accounts gain capacity, from 5 concurrent sandboxes to 15. No account
loses any.

The migration also clears the per-account cap wherever it still held the old
default of 5. A cap that an operator set to another value survives as an
override. An override always beats the plan.

Open `/admin` and read the sandbox column. It shows the enforced cap. The
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

To make an account pay **nothing at all**, comp the account. Open `/admin` and
select `comp` on the row. Fountain cancels the Stripe subscriptions and stops
all charges, contacts included. The teammate keeps the inbox and the number.

To let an account **pay for its plan and still hold a free number**, set the
comped contact count. Open `/admin`, put a number in the field beside the plan,
then select `free`. Fountain bills for the contacts above that count, and for
none if the count covers them all.

The second lever is the one for a staff account, a partner, or a customer you
gave a number to as an apology. The first makes their plan free as well, which
is more than you usually want.

## Reverse the change

Unset the three plan variables. Every account keeps the plan slug it holds,
and `Fountain.Plans` keeps enforcing that plan's cap. The pricing table and
the plan picker go away, because no public plan has a price.

To move one account, open `/admin` and set an override on it.

## Related

- [Start billing](billing.md).
- [Stripe integration guide](../../integrations/stripe.md).
- [Configuration reference](../../configuration.md).
- [See what sandboxes cost](sandbox-spend.md).

<!-- vale STE.IngForms = YES -->
