# See what sandboxes cost

Every conversation runs in a sandbox, and a sandbox costs money for as long as
it runs. This guide shows you how to read that cost per provider, and how to
say which account it belongs to.

## What Fountain measures

Fountain measures active sandbox time. The clock starts when Fountain creates a
sandbox, because a provider charges from the moment it starts to build one. The
clock stops when the sandbox goes away.

Parked time does not count. A suspended sandbox scales to zero and costs almost
nothing. See
[Change sandbox lifetimes](sandbox-lifetime.md) for what parks a sandbox.

Fountain cuts every number to the period you ask about. A sandbox that spans
the end of a month gives each month the time it ran in that month. A sandbox
that has not stopped gives you the time up to now. This is what makes a month
of Fountain numbers comparable with a month of provider invoices.

## Read it in the admin panel

Sign in as an admin and open `/admin`. The **Sandbox spend by provider** panel
shows one card for each provider, with active hours, sandbox count, and how
many accounts are behind it. Below the cards, **Who it belongs to** names the
accounts with the most hours.

The panel is there whether or not you turn billing on. A self-hosted instance <!-- vale disable-line STE.IngForms -->
still pays a provider.

## What each provider means for your bill

| Provider | Who pays |
|---|---|
| `sprites` | You. Time here lands on your Sprites invoice. |
| `e2b` | You. Time here lands on your E2B invoice. |
| `daytona` | You. Time here lands on your Daytona invoice. |
| `runner` | The account that owns the machine. A [self-hosted runner](../../integrations/runners.md) runs on hardware you do not pay for. |

The **Billable to us** line adds up only the first three. The panel shows
runner hours so the picture is complete. It keeps them out of that total so the
total stays true.

## Read one account's own view

Each account sees its own sandbox minutes on `/account/billing`, split by
provider. The same numbers come back from the API.

```bash
curl -sS https://your-instance/api/account/billing \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY"
```

The `usage.sandbox_minutes_by_provider` field holds the split. A provider the
account did not use is absent rather than zero.

## Watch it live

The Prometheus endpoint exports
`fountain_sandboxes_by_provider_count`, tagged by provider and status. Use it
to see how many sandboxes each provider runs right now. It carries no
account tag, because one time series per account would grow without a bound.
Per-account numbers belong in the admin panel and the API, where they are a
column.

See [Wire up observability](observability.md) for how to scrape the endpoint.

## What these numbers are not

They are hours, not money. Providers price by machine size and by contract, and
Fountain holds no rate card. Multiply the hours by the rate you pay.

They also cover sandboxes only. Model inference runs on your users' own
credentials and never reaches a Fountain invoice.

## Related

- [Start billing](billing.md), to charge for what you measure here. <!-- vale disable-line STE.IngForms -->
- [Change sandbox lifetimes](sandbox-lifetime.md), the main lever on the total.
- [About sandboxes](../../concepts/sandboxes.md), for what a sandbox is.
- [Wire up observability](observability.md), for the metrics endpoint.
