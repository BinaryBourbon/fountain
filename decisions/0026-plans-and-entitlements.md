---
type: ADR
title: "Plans priced on concurrent sandboxes, with teammate contacts as a per-unit add-on"
description: "Three public tiers (Solo/Team/Scale) that differ only in the concurrent-sandbox cap Quotas already enforces, a closed `legacy` plan carrying Team capacity at the old flat price, users.sandbox_limit_override demoted to an operator lever, and teammate email/phone billed as a quantity subscription item rather than folded into a tier."
tags: [billing, entitlements, quotas, team-comms]
status: stable
adr: "0026"
adr_status: "Accepted"
date: 2026-08-22
generated: { by: human:jhgaylor, at: 2026-08-22T06:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-22T06:00:00-04:00 }
---

# 0026 — Plans priced on concurrent sandboxes, with teammate contacts as a per-unit add-on

**Status:** Accepted. Everything described here is built: `Fountain.Plans`,
the `users.plan` column and the `sandbox_limit_override` rename-in-Elixir,
`Quotas.sandbox_limit/1` reading from the plan, the price-to-plan mapping in
`Billing.sync_subscription/1`, `Billing.change_plan/3`,
`Billing.sync_contact_addon/1`, the contact ceiling in `Team.Comms`, the plan
picker on `/account/billing`, the pricing table on `/`, and
`mix fountain.verify_plans`. The Stripe prices themselves are an operator
step; see `docs/guides/operate/plans-and-prices.md`.

## Context

Fountain sold one thing: a flat monthly subscription behind a single
`STRIPE_PRICE_ID`, with a 14-day trial (ADR 0006, which explicitly left the
price *shape* undecided). There was no `plan` column and no tier concept
anywhere in the code.

The only per-tenant entitlement that existed was
`users.max_concurrent_sandboxes` — default 5, admin-settable, enforced by
`Fountain.Quotas` at every sandbox creation. It was a de-facto manual tier: an
operator could hand a customer a bigger cap, and nothing tied that cap to what
the customer paid. Everything else the product does was available to everyone
who was past the gate.

#798 laid out the fuller picture: sandbox-active-hours are the honest variable
unit, metering exists but drives nothing, and a real model wants capacity tiers
*plus* metered hours or prepaid credits. That is still true, and it is still
where this is going. It is not what this ADR does.

Separately, teammate comms (#850) let a teammate be given an email inbox and a
phone number, both provisioned under Fountain's own AgentMail and AgentPhone
keys. It shipped behind a PostHog flag with no billing attached at all, and
each contact costs Fountain money every month for as long as it exists.

## Decision

### One axis: concurrent sandboxes

Three public tiers, differing in nothing but the cap `Quotas` already enforces:

| Plan | Concurrent sandboxes | Contact ceiling | Price |
|---|---|---|---|
| Solo | 5 | 3 | $29/mo |
| Team | 15 | 10 | $79/mo |
| Scale | 40 | 40 | $199/mo |

Concurrency is the only axis because it is the only number that is
simultaneously a real cost to Fountain (capacity on the shared provider
account, ADR 0005/0018), already enforced in code, and legible to a customer
with no usage meter in front of them. Everything else the product does stays
on every plan. A feature-gated ladder would need a second enforcement
mechanism, would put the subscription gate back in the business of protecting
features rather than spend (which the 0006 addendum deliberately undid), and
would sell a worse product to the smallest customers.

Sandbox-hours are deliberately **not** part of this. They are the better
variable unit and they remain the plan, but they need the metering correctness
work in #798 first, and shipping tiers does not foreclose them: a tier gains an
included-hours figure later without any of this changing shape.

### `legacy`: grandfathering as a plan, not as a migration

Every account that bought the flat price is on a fourth plan, `legacy`, pinned
to the old `STRIPE_PRICE_ID`. It carries **Team's** capacity at **Solo's**
price, and `public?: false` keeps it out of the pricing table and the plan
picker.

The alternative was to snap everyone to the tier their price maps to. That
would have been Solo, at 5 concurrent — the same number they had — but it
would have made every future capacity decision for those accounts, and it
would have meant the first customers paid the same as new ones for less. A
closed plan says the true thing instead: they are on an earlier deal, they keep
it as long as they like, and every move off it is an upgrade.

`Plans.upgrade?/2` orders `legacy` below every public plan, which is what makes
it structurally upgrade-only. Nothing in the UI can offer a move back onto a
price nobody can buy.

### The cap column becomes an override

`users.max_concurrent_sandboxes` is now the operator's *override*, not the
entitlement. Null means "whatever the plan says", so an upgrade takes effect
without anyone touching the column, and the two situations the override exists
for still work: raise it for a trusted tenant, drop it to zero during abuse.

The Postgres column keeps its name. The Elixir field is
`sandbox_limit_override`, mapped with Ecto's `:source`. This is not squeamishness
about a rename — it is that a rename breaks every pod still running the
previous release for the length of a rolling deploy, while making the column
nullable does not, because the previous release already treats a null as "use
the default". The worst an old pod does mid-rollout is apply the old default of
5, to exactly the rows the migration nulled.

Admin surfaces show the enforced cap and the plan it came from. The API keeps
`max_concurrent_sandboxes` as the *effective* number and adds
`sandbox_limit_override` and `plan` beside it, so nothing reading it breaks.

### The plan follows the Stripe price, and only the webhook writes it

`Billing.change_plan/3` asks Stripe to reprice the subscription's plan item and
writes nothing locally. `customer.subscription.updated` comes back and
`maybe_adopt_plan/3` writes `users.plan` from the price on that subscription.

The entitlement therefore always follows what Stripe actually charges, never
what we asked it to charge. A repricing that half-failed cannot leave a tenant
holding a cap they are not paying for.

Three cases leave the stored plan alone on purpose:

* a `.deleted` event — the account is losing access, not changing tier, and the
  plan it held is what a resubscription should default back to;
* a price this deployment does not recognise — realistically an env var not yet
  set on the replica handling the webhook, and nulling a paying tenant's
  entitlement over that is worse than leaving it stale;
* an event with no items at all.

`Plans.slug_for_price_id/1` answering `nil` for the contact add-on price is
what makes "the first item that names a plan" correct rather than
order-dependent. A tenant with contacts carries two items.

### Teammate contacts: a per-unit add-on, plus a ceiling

An AgentMail inbox and an AgentPhone number are a recurring per-teammate cost,
which is the wrong shape for a flat tier: a tenant with fifteen numbers costs
Fountain fifteen times what a tenant with one does, at the same price. So they
are billed per unit — a second subscription item on the same subscription,
whose quantity `Billing.sync_contact_addon/1` sets to the tenant's contact
count.

**Set, never increment.** The quantity is computed from the contact rows every
time, so a dropped call, an Oban retry, a crash between provisioning and
syncing, or an admin deleting rows directly all converge on the right number at
the next provision or release. An increment would drift, and a drifted
increment bills a tenant for numbers they do not have.

The sync runs *after* the row is committed and is best-effort by rescuing. The
providers have already been paid by that point; a Stripe hiccup must not fail a
provision they completed, or strand a released number as un-released.

That leaves one window: a tenant provisioning in a burst while the sync is
down. `Plans.team_contacts/1` closes it with a per-plan ceiling — an abuse
bound, not an entitlement. Any plan can buy contacts; no plan can buy an
unbounded number of them faster than anyone would notice. The ceiling refuses
with 402 (the same status the subscription gate uses, because the fix is a plan
change and not a retry) and buys nothing before it refuses.

Zero quantity deletes the item rather than setting it to zero: Stripe rejects a
zero quantity on a licensed price, and a lingering item puts "1 × contact" on
the invoice of a tenant who released their last number.

### Self-hosting

`DEFAULT_PLAN` (default `solo`) is the plan for any account with no plan of its
own, which on a self-hosted instance is every account. A self-hoster pays their
own provider bill, so `DEFAULT_PLAN=scale` lifts the cap for everyone at once
without inventing a billing relationship. `BILLING_ENABLED=false` continues to
mean what it meant.

A plan with no price id configured is simply not sellable:
`Billing.available_plans/0` filters on it, so the pricing table and the plan
picker show nothing rather than a button that leads to a Stripe error. This is
also what lets the price ids be rolled out one at a time.

### Drift between the catalog and Stripe

The catalog carries a display price; Stripe carries the charged price; nothing
links them. `mix fountain.verify_plans` does: it reads every configured price
from Stripe and fails if the amount, currency, interval or active flag
disagrees with the catalog. It is read-only and safe against live mode, which
is where it is worth running.

## Consequences

* An upgrade is a real, immediate capacity change, prorated by Stripe, with no
  operator in the loop. That was the missing product motion.
* The subscription gate is unchanged and still protects spend rather than
  features (0006 addendum). Nothing new calls `check_active/1`.
* Two numbers now describe an account's capacity — the plan's and the enforced
  one. Every surface that shows a cap has to show the enforced one, and the
  admin views say which it is.
* Teammate contacts stop being free to Fountain and start being metered by
  count. A tenant on the flag today will see a line item appear on their next
  invoice once `STRIPE_PRICE_ID_CONTACT` is set; setting that variable is
  therefore a customer-facing act, not a config tidy-up.
* The tiers make the #798 hours work easier, not harder, but they also mean a
  later hours model has to fit *inside* a tier rather than replace it.
* Price points are now partly in code (`Fountain.Plans`) and partly in Stripe.
  `verify_plans` is the only thing standing between that and a customer being
  shown one number and charged another. Run it.

## Alternatives considered

**Two tiers instead of three.** Simpler, and the middle tier is where most
customers land, so a ladder without one pushes them to the top or the bottom.
Three gives the upgrade motion somewhere to go.

**Feature-gated tiers.** Rejected above: a second enforcement mechanism, and it
re-entangles the gate with features.

**Contacts included per tier.** Simplest to build and the easiest to explain,
but it prices a genuinely per-unit cost as a flat one. A tier generous enough
for the tenant with fifteen numbers is priced wrong for the tenant with one.

**Contacts as a separate subscription.** A second Stripe subscription per
tenant would mean two invoices, two dunning paths, and a second thing for
`sync_subscription/1` to disambiguate. One subscription with two items keeps
all of that in one place.

Refs: #798, ADR 0005, ADR 0006 (and its 2026-08-05 addendum), ADR 0013,
ADR 0017, ADR 0018.
