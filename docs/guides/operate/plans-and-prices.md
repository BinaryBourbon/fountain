# Prices

<!-- "billing" is a Technical Name here: the product surface, the
     CREDITS_ENABLED flag and the Elixir context all carry it. -->
<!-- vale STE.IngForms = NO -->

This page explains what a tenant pays and what the variables control. There
are no plans. Credits are the product.

## What a tenant pays

| Line | Price | Variable |
|---|---|---|
| One hour of agent time. | 25 cents. | `CREDIT_TURN_HOUR_CENTS`. |
| A phone number, each month. | Unset. | `CREDIT_NUMBER_CENTS`. |
| An email inbox, each month. | Unset. | `CREDIT_INBOX_CENTS`. |
| One email sent. | Unset. | `CREDIT_EMAIL_MESSAGE_CENTS`. |
| One SMS, sent or received. | Unset. | `CREDIT_SMS_MESSAGE_CENTS`. |

An unset price costs nothing. To turn one on is a price increase, and an
explicit act.

An hour of agent time is an hour with a prompt in flight. An agent that waits
for a person spends nothing. Time on a self-hosted runner spends nothing,
because Fountain pays nothing for that machine. Turn time adds up for each
turn. Two conversations that each run for an hour on one sandbox spend two
hours, on a sandbox that was busy for one.

## The opening credit

A new account gets `CREDIT_OPENING_CENTS` ($5) when it verifies its email.
That credit expires `CREDIT_OPENING_DAYS` (14) days later. Credit a tenant
buys never expires, and Fountain spends it last.

## Credit packs

A tenant buys credit on the billing page, or with
`POST /api/account/billing/credits/checkout`. The packs are the amounts in
`CREDIT_PACKS_CENTS`, $10, $25 and $100 by default. Each purchase is a
one-time Stripe Checkout. Stripe reports the payment on the webhook, and
Fountain adds the credit then, not before.

Subscribe your webhook endpoint to `charge.refunded` and
`charge.dispute.created`. On each one, Fountain removes the refunded or
disputed amount from the balance, and the balance can go below zero. Fountain
does not add a disputed amount back when you win the dispute. Add it by hand
from the admin page.

## A zero balance

A zero balance refuses new sandboxes and new turns. A balance can still go
below zero, because a turn that crosses zero finishes. The next purchase
brings it back. Fountain sends an email when the balance falls under 20
percent of the opening credit, and another when it reaches zero.

## Rent for numbers and inboxes

Set `CREDIT_NUMBER_CENTS` and `CREDIT_INBOX_CENTS`, and each teammate contact
costs one month of rent up front, then one month on each monthly
anniversary. Fountain takes the rent from the balance. Fountain refuses a new
contact when the balance cannot cover the first month. A contact with unpaid
rent gets seven days of grace. Fountain sends a reminder on day 0, day 3 and
day 6. On day 7 it releases the number and the inbox. You cannot recover a
released number. A top-up during the grace pays the rent and keeps the
number.

`TEAM_CONTACT_CEILING` (10) is the most contacts one account may hold at once.
It is an abuse ceiling, not a price.

## How many agents at once

A tenant may run as many sandboxes at once as the balance funds: one for each
`SANDBOX_RESERVE_CENTS` ($2) in the balance, from `SANDBOX_CAP_FLOOR` (2) up
to `SANDBOX_CAP_CEILING` (20). An admin override on the account wins. The
whole deployment stops at `SANDBOX_FLEET_CEILING` (20). Set that to what your
sandbox provider plan allows.

The two limits feed the same bounded queue. A fresh API start can set
`queue: true`. Fountain then returns `202` and lets the request wait when the
tenant cap or the fleet ceiling blocks it. Scheduled teammate runs always
use the queue. Other callers keep the immediate `429` or `503` response.

Each tenant can hold ten requests. A request can wait for one hour. Set these
bounds with `SANDBOX_QUEUE_MAX_DEPTH` and
`SANDBOX_QUEUE_MAX_WAIT_SECONDS`. At the depth bound, Fountain refuses the
request. After the wait bound, Fountain expires it. The queue delays the cap.
It never raises it, and a start must still pass the credit gate when it runs.

## Give someone free credit

To make an account pay **nothing at all**, comp the account. Open
`/admin/users` and select `comp` on the row, or send
`POST /api/admin/users/{id}/comp` with `{"comped": true}`. Fountain never
checks that account's balance.

To give an account credit that never expires, use the admin API:
`POST /api/admin/users/{id}/credits` with `{"cents": 1000, "note": "why"}`.

## See the money

`/admin/finance` shows credit earned, sold and deferred, the cost of each
provider, and the invoice you record next to the computed figure. See
[See what sandboxes cost](sandbox-spend.md).

## Related

- [Start billing](billing.md).
- [Stripe integration guide](../../integrations/stripe.md).

<!-- vale STE.IngForms = YES -->
