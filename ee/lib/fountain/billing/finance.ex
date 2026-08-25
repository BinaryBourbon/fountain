defmodule Fountain.Billing.Finance do
  @moduledoc """
  What Fountain is paid and what Fountain pays, per tenant, over a period.

  The pieces have existed for a while and never met. `Billing.overview_admin/1`
  had revenue with no cost beside it, `Billing.provider_spend/1` had cost with
  no revenue beside it and deliberately no money in it at all, and
  `Billing.turn_hour_allowance/2` had the sold unit but only ever for one
  tenant at a time. This module puts the three on one row so the question
  "which tenants cost more than they pay" has an answer.

  ## Revenue

  Two lines, both from what the tenant is actually subscribed to:

    * the **plan** — `Fountain.Plans.monthly_cents/1` for their tier;
    * the **teammate-contact add-on** — the billable contact count times
      `Plans.contact_monthly_cents/0` (#991), less the contacts an operator
      has comped.

  Contact revenue is what `sync_contact_addon/1` would actually put on the
  invoice, guards included — **not** the contact count times a price. Where a
  deployment has no `STRIPE_PRICE_ID_CONTACT` (the state one stays in until an
  operator deliberately leaves it, because setting it bills every existing
  tenant on their next invoice) the add-on earns nothing, however many
  contacts exist. `Plans.contact_monthly_cents/0` returns $5 regardless of
  whether anything is configured to charge it, which is exactly how this panel
  came to report revenue no invoice contained. The cost side still counts
  every inbox and number, because Fountain pays for those either way.

  Only an `active` subscription contributes. A trialing account pays nothing
  yet and a comped one pays nothing by decision, so both count as zero
  revenue against real cost — which is the point of looking. `past_due` is
  reported apart as at-risk rather than folded into MRR: it is revenue that
  has not arrived.

  Every row carries two plans, because since #1022 they can differ. `:plan` is
  `Plans.resolve/1` — the tier the subscription is *for*, which is what a
  trial converts into and what its revenue lines are priced at.
  `:effective_plan` is `Plans.effective/1` — whose entitlements apply *today*,
  which during a trial is the smaller `trial` plan. The allowance columns read
  the second. Reading the first would measure a trialing account against hours
  it does not have yet, and report it inside an allowance it is over.

  ## Cost, and the rate card

  Fountain's spend is not in this codebase, and inventing it would make this
  page look authoritative when it is not — the reasoning `provider_spend/1`
  already committed to. So cost is priced from a **rate card in config**, and
  where the card is silent the answer is `nil`, never a guess:

  | Config key | Env var | Unit |
  |---|---|---|
  | `:provider_hourly_cents` | `PROVIDER_HOURLY_CENTS` | cents per sandbox hour, per provider |
  | `:cost_basis` | `PROVIDER_COST_BASIS` | `active` (default) or `turn` — which hours that rate multiplies |
  | `:agentmail_inbox_cents` | `AGENTMAIL_INBOX_CENTS` | cents per inbox per month |
  | `:agentphone_number_cents` | `AGENTPHONE_NUMBER_CENTS` | cents per number per month |
  | `:agentmail_message_cents` | `AGENTMAIL_MESSAGE_CENTS` | cents per email sent |
  | `:agentphone_message_cents` | `AGENTPHONE_MESSAGE_CENTS` | cents per SMS, each way |

  **Every rate may be fractional.** Per-message rates in particular usually
  are — AgentMail bills roughly $0.002 an email, which as a whole number of
  cents is zero. Rates stay fractional through the arithmetic and each cost
  component rounds to whole cents exactly once, at the end.

  One rate card covers every provider, and it prices them all on the same
  basis. That is right while the providers Fountain actually bills for behave
  the same way, and `sprites` (asleep after 30s idle, billed awake) and `e2b`
  (billed until paused) do not. Today it does not bite — every hour on the
  bill is a Sprites hour — but a deployment with real traffic on both wants a
  per-provider basis, not this.

  `nil` propagates: a tenant with sandbox hours on a provider that has no rate
  has `cost_cents: nil`, not a cost that silently omits them, and their margin
  is `nil` too. `priced?/0` says whether the card covers anything at all, so a
  surface can offer hours instead of dollars rather than showing zeroes. A
  self-hosted instance sets none of it and gets exactly the hours report it
  had before.

  ## Three kinds of cost, three shapes

  **Sandbox hours** come in two flavours and the panel prices whichever one
  the invoice actually tracks. `:active` is the whole window a sprite was
  awake, idle included; `:turn` is only the part with a prompt in flight. A
  provider that bills wall-clock matches the first, and one that scales to
  near-zero between prompts matches the second closely enough to reconcile
  against. `:cost_basis` on the config (`PROVIDER_COST_BASIS`) sets the
  default and `summary/1` takes a `:basis` override, because the way to find
  out which one a provider bills is to hold both next to the invoice.

  Every row carries active hours **and** turn hours whichever basis is
  chosen, because the gap between them is the tenant's idle time and it is
  the single largest lever on the bill. Turn hours are also what burns a
  tenant's prepaid credit (ADR 0030), so on the `:turn` basis cost and burn
  move together, and on `:active` they do not.

  **Credits** are the usage revenue: what a period's tier grants put in, what
  turns and contacts burned, what packs sold, and the deferred balance —
  money taken and not yet burned, which is a liability rather than revenue
  until it is.

  **Contacts** are a monthly recurring charge per inbox and per number, so
  they are pro-rated against the period rather than charged whole: a panel
  looking at a week of a month should not show a month of AgentMail. The
  channels are counted apart (`Team.Comms.channel_counts/0`) because the two
  providers charge differently and a contact can hold either, neither or both.

  **Messages** are per-send, from the `comms_email_sent`, `comms_sms_sent` and
  `comms_sms_received` usage events (`FountainWeb.TeamCommsMcpController`,
  `Team.Comms.Inbound`). Inbound counts: AgentPhone charges to receive.

  ## Cost, ownership and the tenants that are not there

  Sandbox seconds whose owner has been deleted keep a `nil` `user_id` all the
  way through `SandboxUsage` (decisions/0009). They are real spend and they
  are in `:unattributed_cost_cents`, out of the per-tenant rows, because there
  is no tenant to put them on. A total that quietly dropped them would
  understate the bill.

  ## Cost

  `summary/1` is four queries plus the two `SandboxUsage.attribution/3`
  already runs — one pass for every tenant, not a query per row. The finance
  panel refreshes on a timer, and so does `/admin`.
  """

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Billing.SandboxUsage
  alias Fountain.Billing.UsageEvent
  alias Fountain.Plans
  alias Fountain.Repo
  alias Fountain.Team.Comms

  @message_events ~w(comms_email_sent comms_sms_sent comms_sms_received)

  # Statuses that are paying today. `trialing` will be, `past_due` was, and
  # `comped` never will be — none of them is MRR.
  @paying ~w(active)

  @typedoc "One tenant's money for a period. Every `*_cents` may be `nil` when the rate card is silent."
  @type tenant_row :: %{
          user_id: binary(),
          email: String.t(),
          plan: Plans.t(),
          effective_plan: Plans.t(),
          subscription_status: String.t(),
          revenue_cents: non_neg_integer(),
          plan_cents: non_neg_integer(),
          contact_revenue_cents: non_neg_integer(),
          turn_hours: float(),
          credit_granted_cents: non_neg_integer(),
          credit_burned_cents: non_neg_integer(),
          credit_sold_cents: non_neg_integer(),
          credit_balance_cents: integer(),
          active_hours: float(),
          idle_hours: float(),
          inboxes: non_neg_integer(),
          numbers: non_neg_integer(),
          emails_sent: non_neg_integer(),
          sms_sent: non_neg_integer(),
          sms_received: non_neg_integer(),
          sandbox_cost_cents: non_neg_integer() | nil,
          contact_cost_cents: non_neg_integer() | nil,
          message_cost_cents: non_neg_integer() | nil,
          cost_cents: non_neg_integer() | nil,
          margin_cents: integer() | nil
        }

  ## ── the rate card ───────────────────────────────────────────────────────

  @doc """
  What this deployment says it pays, in cents. Absent keys mean "unpriced",
  which is a different answer from zero and is reported as `nil` throughout.
  """
  @spec rate_card() :: %{
          providers: %{optional(String.t()) => non_neg_integer()},
          basis: :active | :turn,
          inbox_month: non_neg_integer() | nil,
          number_month: non_neg_integer() | nil,
          email: non_neg_integer() | nil,
          sms: non_neg_integer() | nil
        }
  def rate_card(basis \\ nil) do
    %{
      providers: provider_rates(),
      basis: basis || default_basis(),
      inbox_month: rate(:agentmail_inbox_cents),
      number_month: rate(:agentphone_number_cents),
      email: rate(:agentmail_message_cents),
      sms: rate(:agentphone_message_cents)
    }
  end

  @doc """
  The hours a provider rate multiplies, unless a caller overrides it.

  `:active` — every hour the sandbox was awake — unless
  `PROVIDER_COST_BASIS=turn` says this deployment's providers bill closer to
  prompt time. Anything else reads as `:active`: a misspelt env var must not
  silently halve the reported bill.
  """
  @spec default_basis() :: :active | :turn
  def default_basis do
    case Application.get_env(:fountain, :cost_basis) do
      :turn -> :turn
      "turn" -> :turn
      _ -> :active
    end
  end

  @doc "Both bases, for a surface that offers the choice."
  @spec bases() :: [:active | :turn]
  def bases, do: [:active, :turn]

  @doc """
  Whether the rate card prices anything at all.

  False on a fresh or self-hosted instance, where the panel shows hours and
  units and says out loud that it has no rates — which is the honest state,
  not an error.
  """
  @spec priced?() :: boolean()
  def priced? do
    card = rate_card()

    card.providers != %{} or
      Enum.any?([card.inbox_month, card.number_month, card.email, card.sms], &(&1 != nil))
  end

  defp provider_rates do
    case Application.get_env(:fountain, :provider_hourly_cents) do
      map when is_map(map) -> map
      _ -> %{}
    end
  end

  # Fractional cents are the normal case, not an edge one: AgentMail bills
  # around $0.002 an email, so a whole-cent rate rounds it to zero and the
  # panel reports email as free. Rates stay fractional through the
  # arithmetic; each cost component rounds to whole cents once, at the end.
  defp rate(key) do
    case Application.get_env(:fountain, key) do
      cents when is_number(cents) and cents >= 0 -> cents
      _ -> nil
    end
  end

  ## ── the whole panel ─────────────────────────────────────────────────────

  @doc """
  Everything the finance panel renders, in one pass.

  Options:
    * `:period` — `{start, end}`, default the current calendar month. Per-user
      billing periods are deliberately not used here: the panel adds tenants
      together, and a sum over windows that each start on a different day is
      not a number anyone can hold next to a provider invoice. Each tenant's
      own invoiced window stays on their detail page.
    * `:basis` — `:active` or `:turn`, which hours the provider rates
      multiply. Defaults to `default_basis/0`. See the moduledoc: the way to
      learn which one a provider bills is to compare both against an invoice.
    * `:now` — pins the clock (tests)

  Returns `%{period_start:, period_end:, priced?:, rate_card:, revenue:,
  cost:, turn_hours:, tenants:, unattributed_cost_cents:}`. `rate_card.basis`
  says which hours were priced, so a surface can label its own number.
  """
  @spec summary(keyword()) :: map()
  def summary(opts \\ []) do
    {period_start, period_end} = Keyword.get(opts, :period) || Billing.current_month_range()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    rows = SandboxUsage.attribution(period_start, period_end, now: now)
    users = paying_users()
    card = rate_card(Keyword.get(opts, :basis))
    fraction = period_fraction(period_start, period_end, now)

    usage = usage_by_user(rows)
    channels = Comms.channel_counts()
    messages = message_counts(period_start, period_end)
    contacts = billable_contacts(users)
    ledger = ledger_by_user(period_start, period_end)

    tenants =
      users
      |> Enum.map(
        &tenant_row(
          &1,
          Map.get(usage, &1.id, empty_usage()),
          Map.get(channels, &1.id, %{inboxes: 0, numbers: 0}),
          Map.get(messages, &1.id, empty_messages()),
          Map.get(contacts, &1.id, 0),
          Map.get(ledger, &1.id, empty_ledger()),
          card,
          fraction
        )
      )
      |> Enum.sort_by(&sort_key/1)

    %{
      period_start: period_start,
      period_end: period_end,
      period_fraction: fraction,
      priced?: priced?(),
      rate_card: card,
      revenue: revenue(tenants),
      cost: cost(tenants, rows, card),
      credits: credits(tenants),
      tenants: tenants,
      unattributed_cost_cents: unattributed_cost_cents(rows, card)
    }
  end

  # Biggest loss first, then biggest cost — the row an operator opened the
  # page for. An unpriced deployment has no margin to sort on and falls back
  # to sandbox hours, which is the only cost signal it has.
  defp sort_key(%{margin_cents: nil, active_hours: hours}), do: {0, -hours}
  defp sort_key(%{margin_cents: margin}), do: {-1, margin}

  ## ── revenue ─────────────────────────────────────────────────────────────

  @doc """
  Recurring revenue, by plan, from the tenant rows `summary/1` built.

  `:mrr_cents` counts `active` subscriptions only. It replaced a single
  `active × STRIPE_PRICE_MONTHLY_CENTS`, which had been silently wrong since
  the tiers landed (#991): it charged every active account the legacy price,
  so a deployment selling Scale under-reported its own revenue by a factor of
  seven.

  `:at_risk_cents` is what `past_due` accounts would be paying, and
  `:comped_cents` what comped ones would — both real numbers an operator
  wants, neither of them MRR.
  """
  @spec revenue([tenant_row()]) :: map()
  def revenue(tenants) when is_list(tenants) do
    paying = Enum.filter(tenants, &(&1.subscription_status in @paying))

    by_plan =
      paying
      |> Enum.group_by(& &1.plan.slug)
      |> Enum.map(fn {slug, group} ->
        %{
          plan: Plans.resolve(slug),
          accounts: length(group),
          plan_cents: group |> Enum.map(& &1.plan_cents) |> Enum.sum(),
          contact_cents: group |> Enum.map(& &1.contact_revenue_cents) |> Enum.sum()
        }
      end)
      |> Enum.sort_by(& &1.plan.order)

    %{
      mrr_cents: paying |> Enum.map(& &1.revenue_cents) |> Enum.sum(),
      plan_cents: paying |> Enum.map(& &1.plan_cents) |> Enum.sum(),
      contact_cents: paying |> Enum.map(& &1.contact_revenue_cents) |> Enum.sum(),
      # Packs sold in the period, by anyone. Not MRR: one-time, and a
      # liability until burned (`credits/1` carries the deferred balance).
      credit_sales_cents: tenants |> Enum.map(& &1.credit_sold_cents) |> Enum.sum(),
      by_plan: by_plan,
      at_risk_cents: status_cents(tenants, "past_due"),
      comped_cents: status_cents(tenants, "comped"),
      trialing_cents: status_cents(tenants, "trialing")
    }
  end

  # What a non-paying cohort *would* bill at their current plan — the size of
  # the conversion, or of the discount.
  defp status_cents(tenants, status) do
    tenants
    |> Enum.filter(&(&1.subscription_status == status))
    |> Enum.map(&(&1.plan_cents + &1.contact_revenue_cents))
    |> Enum.sum()
  end

  @doc """
  Monthly recurring revenue on its own, in two grouped queries — for `/admin`,
  which wants the number without the whole finance pass behind it.

  Same arithmetic as `revenue/1`, and `finance_test.exs` asserts the two agree:
  a tile and a table that disagree about MRR is how an operator stops trusting
  both.

  Replaces `active × STRIPE_PRICE_MONTHLY_CENTS`, which had been quietly wrong
  since the tiers landed (#991) — it charged every active account the legacy
  $29, so a deployment selling Scale under-reported itself sevenfold.
  """
  @spec mrr() :: %{
          mrr_cents: non_neg_integer(),
          plan_cents: non_neg_integer(),
          contact_cents: non_neg_integer(),
          by_plan: [map()]
        }
  def mrr do
    counts =
      Repo.all(
        from u in User,
          where: u.subscription_status in ^@paying,
          group_by: u.plan,
          select: {u.plan, count(u.id)}
      )

    contacts = active_contact_cents()

    by_plan =
      counts
      |> Enum.map(fn {slug, accounts} ->
        plan = Plans.resolve(slug)

        %{
          plan: plan,
          accounts: accounts,
          plan_cents: accounts * plan.monthly_cents,
          contact_cents: Map.get(contacts, plan.slug, 0)
        }
      end)
      # A null `plan` and an unknown slug both resolve to the deployment
      # default, so two groups can land on one plan; merge them rather than
      # rendering the same tier twice.
      |> Enum.group_by(& &1.plan.slug)
      |> Enum.map(fn {_slug, group} ->
        %{
          plan: hd(group).plan,
          accounts: group |> Enum.map(& &1.accounts) |> Enum.sum(),
          plan_cents: group |> Enum.map(& &1.plan_cents) |> Enum.sum(),
          contact_cents: hd(group).contact_cents
        }
      end)
      |> Enum.sort_by(& &1.plan.order)

    plan_cents = by_plan |> Enum.map(& &1.plan_cents) |> Enum.sum()
    contact_cents = by_plan |> Enum.map(& &1.contact_cents) |> Enum.sum()

    %{
      mrr_cents: plan_cents + contact_cents,
      plan_cents: plan_cents,
      contact_cents: contact_cents,
      by_plan: by_plan
    }
  end

  # Contact add-on revenue for active accounts only, grouped by the plan they
  # are on, so the per-plan table's two columns come from the same cohort.
  #
  # Empty on a deployment that does not bill contacts, which is what keeps the
  # `/admin` MRR tile and this panel telling the same story: both read this,
  # and both used to add $5 a contact against invoices charging nothing.
  defp active_contact_cents do
    users =
      Repo.all(
        from u in User,
          where: u.subscription_status in ^@paying,
          select: %{
            id: u.id,
            plan: u.plan,
            subscription_status: u.subscription_status,
            stripe_subscription_id: u.stripe_subscription_id
          }
      )

    billable = billable_contacts(users)

    Enum.reduce(users, %{}, fn user, acc ->
      case Map.get(billable, user.id, 0) do
        0 ->
          acc

        count ->
          key = Plans.resolve(user.plan).slug
          Map.update(acc, key, count, &(&1 + count))
      end
    end)
    |> Map.new(fn {slug, count} -> {slug, count * Plans.contact_monthly_cents()} end)
  end

  ## ── cost ────────────────────────────────────────────────────────────────

  @doc """
  Platform spend for the period: the hours behind it, and the money when the
  rate card can price them.

  `:sandbox_cents` covers every provider Fountain pays for — including the
  seconds of deleted accounts, which is why it is computed from the raw
  attribution rows rather than by adding the tenant rows up.
  """
  @spec cost([tenant_row()], [SandboxUsage.row()], map()) :: map()
  def cost(tenants, rows, card) do
    paid = Enum.filter(rows, &SandboxUsage.platform_cost?(&1.provider))

    %{
      active_hours: paid |> Enum.map(& &1.active_seconds) |> Enum.sum() |> SandboxUsage.hours(),
      idle_hours: paid |> Enum.map(& &1.idle_seconds) |> Enum.sum() |> SandboxUsage.hours(),
      basis: card.basis,
      sandbox_cents:
        sum_or_nil(paid, &provider_cost_cents(billed_seconds(&1, card.basis), &1.provider, card)),
      # Only meaningful on the `:active` basis: on `:turn` the idle hours are
      # already outside the bill, so there is nothing for a shorter timeout to
      # remove and reporting a saving would be an invention.
      idle_cents:
        if(card.basis == :active,
          do: sum_or_nil(paid, &provider_cost_cents(&1.idle_seconds, &1.provider, card))
        ),
      contact_cents: sum_or_nil(tenants, & &1.contact_cost_cents),
      message_cents: sum_or_nil(tenants, & &1.message_cost_cents),
      inboxes: tenants |> Enum.map(& &1.inboxes) |> Enum.sum(),
      numbers: tenants |> Enum.map(& &1.numbers) |> Enum.sum(),
      emails_sent: tenants |> Enum.map(& &1.emails_sent) |> Enum.sum(),
      sms_sent: tenants |> Enum.map(& &1.sms_sent) |> Enum.sum(),
      sms_received: tenants |> Enum.map(& &1.sms_received) |> Enum.sum(),
      by_provider: SandboxUsage.by_provider(rows)
    }
  end

  # The spend nobody can be charged for: sandboxes whose owner has been
  # deleted. Real money, no tenant row.
  defp unattributed_cost_cents(rows, card) do
    rows
    |> Enum.filter(&(is_nil(&1.user_id) and SandboxUsage.platform_cost?(&1.provider)))
    |> sum_or_nil(&provider_cost_cents(billed_seconds(&1, card.basis), &1.provider, card))
  end

  ## ── credits ─────────────────────────────────────────────────────────────

  @doc """
  The prepaid ledger over the period (ADR 0030): what the tier grants put in,
  what burned, what packs sold, and the deferred balance — the sum of every
  positive balance today, which is money already taken for work not yet
  done. Burned against granted-plus-sold is the utilisation of what tenants
  hold; a deferred balance that only grows is revenue that is not arriving.
  """
  @spec credits([tenant_row()]) :: map()
  def credits(tenants) do
    granted = tenants |> Enum.map(& &1.credit_granted_cents) |> Enum.sum()
    burned = tenants |> Enum.map(& &1.credit_burned_cents) |> Enum.sum()
    sold = tenants |> Enum.map(& &1.credit_sold_cents) |> Enum.sum()

    %{
      granted_cents: granted,
      burned_cents: burned,
      sold_cents: sold,
      deferred_cents: deferred_cents(),
      negative_balances: Enum.count(tenants, &(&1.credit_balance_cents < 0)),
      utilization: if(granted + sold > 0, do: Float.round(burned / (granted + sold), 4))
    }
  end

  # Every positive balance, whoever holds it — a deleted account's ledger is
  # gone with the account (ADR 0009), so this is what is owed today.
  defp deferred_cents do
    Repo.one(
      from u in User,
        where: u.credit_balance_cents > 0,
        select: coalesce(sum(u.credit_balance_cents), 0)
    )
  end

  ## ── one tenant ──────────────────────────────────────────────────────────

  defp tenant_row(user, usage, channels, messages, contacts, ledger, card, fraction) do
    # `plan` is the tier the subscription is for — what Stripe charges, and
    # what a trial converts into. `effective_plan` is whose numbers apply
    # today, which during a trial is the smaller `trial` plan (#1022).
    #
    # Revenue reads the first and the grant reads the second, and using one
    # for the other is the specific mistake this split exists to prevent: a
    # trialing account is granted the trial's $10, not its future tier's $50.
    plan = Plans.resolve(user)
    effective_plan = Plans.effective(user)
    paying? = user.subscription_status in @paying

    plan_cents = plan.monthly_cents
    contact_revenue_cents = contacts * Plans.contact_monthly_cents()

    sandbox_cost =
      sum_or_nil(
        usage.by_provider,
        &provider_cost_cents(billed_seconds(&1, card.basis), &1.provider, card)
      )

    contact_cost = contact_cost_cents(channels, card, fraction)
    message_cost = message_cost_cents(messages, card)
    turn_seconds = billable_turn_seconds(usage)

    cost = add_or_nil([sandbox_cost, contact_cost, message_cost])

    # Revenue is what they are billed *this month*, so it is the full monthly
    # price rather than a pro-rated one, while the recurring contact cost above
    # is pro-rated to the window being looked at. They are answering different
    # questions and a part-month view will show the two out of step; the panel
    # says which window it is on.
    revenue_cents = if paying?, do: plan_cents + contact_revenue_cents, else: 0

    %{
      user_id: user.id,
      email: user.email,
      plan: plan,
      subscription_status: user.subscription_status,
      revenue_cents: revenue_cents,
      plan_cents: plan_cents,
      contact_revenue_cents: contact_revenue_cents,
      turn_hours: SandboxUsage.hours(turn_seconds),
      effective_plan: effective_plan,
      credit_granted_cents: ledger.granted,
      credit_burned_cents: ledger.burned,
      credit_sold_cents: ledger.sold,
      credit_balance_cents: user.credit_balance_cents,
      active_hours: SandboxUsage.hours(usage.active_seconds),
      idle_hours: SandboxUsage.hours(usage.idle_seconds),
      inboxes: channels.inboxes,
      numbers: channels.numbers,
      emails_sent: messages.emails_sent,
      sms_sent: messages.sms_sent,
      sms_received: messages.sms_received,
      sandbox_cost_cents: sandbox_cost,
      contact_cost_cents: contact_cost,
      message_cost_cents: message_cost,
      cost_cents: cost,
      margin_cents: cost && revenue_cents - cost
    }
  end

  # Turn seconds that spend a tenant's allowance: the providers Fountain pays
  # for, so a tenant's own runner (ADR 0022) is excluded, summed per turn
  # rather than the sandbox's busy union (ADR 0023 step 6). The same filter and
  # the same figure `Billing.turn_hours_used/2` applies, and it has to be the
  # same one — the allowance shown here and the allowance shown on the tenant's
  # own billing page cannot come apart.
  defp billable_turn_seconds(usage) do
    usage.by_provider
    |> Enum.filter(&SandboxUsage.platform_cost?(&1.provider))
    |> Enum.map(& &1.turn)
    |> Enum.sum()
  end

  # Monthly charges, pro-rated to the window. Zero units costs zero whether or
  # not there is a rate — a tenant with no inbox is not unpriced.
  ## ── pricing helpers ─────────────────────────────────────────────────────

  # Which seconds a provider rate multiplies. The two row shapes in play name
  # the same two numbers differently — `SandboxUsage.row()` has
  # `active_seconds`/`busy_seconds`, the per-tenant fold has `active`/`busy` —
  # so both are read here rather than at four call sites.
  defp billed_seconds(%{active_seconds: active}, :active), do: active
  defp billed_seconds(%{busy_seconds: busy}, :turn), do: busy
  defp billed_seconds(%{active: active}, :active), do: active
  defp billed_seconds(%{busy: busy}, :turn), do: busy

  # `nil` for a provider the rate card does not name, and for one Fountain
  # does not pay at all (a tenant's own runner, ADR 0022) — but zero for the
  # runner rather than nil, because "we pay nothing for this" is a known
  # price, not a missing one.
  defp provider_cost_cents(seconds, provider, card) do
    cond do
      not SandboxUsage.platform_cost?(provider) -> 0
      rate = Map.get(card.providers, provider) -> round(seconds / 3600 * rate)
      true -> nil
    end
  end

  # Monthly charges, pro-rated to the window. Zero units costs zero whether or
  # not there is a rate — a tenant with no inbox is not unpriced.
  defp contact_cost_cents(%{inboxes: 0, numbers: 0}, _card, _fraction), do: 0

  defp contact_cost_cents(%{inboxes: inboxes, numbers: numbers}, card, fraction) do
    add_or_nil([
      monthly_cost(inboxes, card.inbox_month, fraction),
      monthly_cost(numbers, card.number_month, fraction)
    ])
  end

  defp monthly_cost(0, _cents, _fraction), do: 0
  defp monthly_cost(_units, nil, _fraction), do: nil
  defp monthly_cost(units, cents, fraction), do: round(units * cents * fraction)

  defp message_cost_cents(%{emails_sent: 0, sms_sent: 0, sms_received: 0}, _card), do: 0

  defp message_cost_cents(messages, card) do
    # Rounded once from the total rather than per channel: at $0.002 an email,
    # rounding each channel first turns 400 emails and 10 texts into `0 + 20`
    # instead of `80 + 20`.
    [
      per_message(messages.emails_sent, card.email),
      # AgentPhone charges "$0.02/message (inbound and outbound)", so both
      # directions are billed at the one rate.
      per_message(messages.sms_sent + messages.sms_received, card.sms)
    ]
    |> add_or_nil()
    |> then(&(&1 && round(&1)))
  end

  defp per_message(0, _cents), do: 0
  defp per_message(_count, nil), do: nil
  defp per_message(count, cents), do: count * cents

  # `nil` is contagious: a total missing one of its parts is not a total. It
  # must not silently become the sum of the parts that happened to be priced.
  defp add_or_nil(parts) do
    if Enum.any?(parts, &is_nil/1), do: nil, else: Enum.sum(parts)
  end

  defp sum_or_nil(items, fun) do
    items |> Enum.map(fun) |> add_or_nil()
  end

  ## ── the reads ───────────────────────────────────────────────────────────

  # Every account that can carry a plan. Deleted accounts are gone; suspended
  # ones are still subscribed and still cost money, so they stay.
  defp paying_users do
    Repo.all(
      from u in User,
        select: %{
          id: u.id,
          email: u.email,
          plan: u.plan,
          subscription_status: u.subscription_status,
          credit_balance_cents: u.credit_balance_cents,
          # Not decoration: an account with no subscription has no item for
          # the contact add-on to sit on, so `sync_contact_addon/1` bills it
          # nothing however many contacts it holds.
          stripe_subscription_id: u.stripe_subscription_id
        }
    )
  end

  @doc """
  Whether this deployment puts teammate contacts on an invoice at all.

  False when billing is off, and false when `STRIPE_PRICE_ID_CONTACT` is
  unset — which is the state a deployment stays in until an operator
  deliberately leaves it, because setting that variable adds a line item to
  the next invoice of every tenant who already holds contacts (#991).

  While it is false the contacts are real, they cost Fountain real money, and
  they earn nothing. That is a fact worth seeing rather than a zero to hide,
  so the panel says it out loud.
  """
  @spec contacts_billed?() :: boolean()
  def contacts_billed?, do: Billing.enabled?() and not is_nil(Plans.contact_price_id())

  # The billable contact quantity per tenant: what `sync_contact_addon/1`
  # would actually set the Stripe item to, in one query rather than one per
  # row.
  #
  # It is not enough to copy `billable_contacts/1`'s subtraction, which is
  # what this did and why the panel invented revenue. That function is the
  # *last* step of `sync_contact_addon/1`, behind four guards that each mean
  # "nothing is billed": billing off, no contact price on this deployment, a
  # comped account, or an account with no Stripe subscription to hang an item
  # on. Prod sits behind the second of those, so every contact was reported at
  # $5 a month against invoices that charge nothing for them.
  defp billable_contacts(users) do
    if contacts_billed?() do
      counts = Comms.contact_counts()

      comped =
        Repo.all(from u in User, where: u.comped_contacts > 0, select: {u.id, u.comped_contacts})
        |> Map.new()

      billable =
        Map.new(users, fn user ->
          {user.id, user.subscription_status != "comped" and subscribed?(user)}
        end)

      Map.new(counts, fn {user_id, count} ->
        if Map.get(billable, user_id, false) do
          {user_id, max(count - Map.get(comped, user_id, 0), 0)}
        else
          {user_id, 0}
        end
      end)
    else
      %{}
    end
  end

  defp subscribed?(%{stripe_subscription_id: id}), do: id not in [nil, ""]
  defp subscribed?(_), do: false

  # Message counts per tenant for the period, one grouped query over the same
  # `usage_events` table the sandbox counts come from.
  defp message_counts(period_start, period_end) do
    from(e in UsageEvent,
      where:
        e.inserted_at >= ^period_start and e.inserted_at < ^period_end and
          e.event_type in @message_events and not is_nil(e.user_id),
      group_by: [e.user_id, e.event_type],
      select: {e.user_id, e.event_type, count(e.id)}
    )
    |> Repo.all()
    |> Enum.reduce(%{}, fn {user_id, type, count}, acc ->
      counts = Map.get(acc, user_id, empty_messages())

      Map.put(acc, user_id, %{
        counts
        | emails_sent: counts.emails_sent + if(type == "comms_email_sent", do: count, else: 0),
          sms_sent: counts.sms_sent + if(type == "comms_sms_sent", do: count, else: 0),
          sms_received: counts.sms_received + if(type == "comms_sms_received", do: count, else: 0)
      })
    end)
  end

  defp empty_messages, do: %{emails_sent: 0, sms_sent: 0, sms_received: 0}

  # One pass over the ledger for the period: cents granted, burned and sold
  # per tenant. Expiries and clawbacks are neither — an expiry is credit that
  # was never earned, a clawback is money that went back.
  defp ledger_by_user(period_start, period_end) do
    from(e in Fountain.Credits.LedgerEntry,
      where: e.inserted_at >= ^period_start and e.inserted_at < ^period_end,
      group_by: e.user_id,
      select:
        {e.user_id,
         %{
           granted:
             fragment(
               "coalesce(sum(case when ? like 'grant_%' then ? end), 0)",
               e.reason,
               e.amount_cents
             ),
           burned:
             fragment(
               "coalesce(sum(case when ? like 'burn_%' then -? end), 0)",
               e.reason,
               e.amount_cents
             ),
           sold:
             fragment(
               "coalesce(sum(case when ? = 'purchase' then ? end), 0)",
               e.reason,
               e.amount_cents
             )
         }}
    )
    |> Repo.all()
    |> Map.new()
  end

  defp empty_ledger, do: %{granted: 0, burned: 0, sold: 0}

  defp empty_usage,
    do: %{active_seconds: 0, busy_seconds: 0, idle_seconds: 0, by_provider: []}

  @doc """
  `SandboxUsage.attribution/3` rows folded per tenant, keeping the per-provider
  split the totals were built from.

  `SandboxUsage.by_user/1` collapses to `%{provider => active_seconds}`, which
  loses both the busy/idle split and the ability to price a provider at its
  own rate. Public because `/admin`'s user table wants the same fold for the
  turn hours on each row.
  """
  @spec usage_by_user([SandboxUsage.row()]) :: %{optional(binary()) => map()}
  def usage_by_user(rows) when is_list(rows) do
    rows
    |> Enum.reject(&is_nil(&1.user_id))
    |> Enum.group_by(& &1.user_id)
    |> Map.new(fn {user_id, group} ->
      {user_id,
       %{
         active_seconds: group |> Enum.map(& &1.active_seconds) |> Enum.sum(),
         busy_seconds: group |> Enum.map(& &1.busy_seconds) |> Enum.sum(),
         idle_seconds: group |> Enum.map(& &1.idle_seconds) |> Enum.sum(),
         turn_seconds: group |> Enum.map(& &1.turn_seconds) |> Enum.sum(),
         by_provider:
           Enum.map(
             group,
             &%{
               provider: &1.provider,
               active: &1.active_seconds,
               busy: &1.busy_seconds,
               idle: &1.idle_seconds,
               turn: &1.turn_seconds
             }
           )
       }}
    end)
  end

  @doc """
  How much of the period has actually elapsed, `0.0..1.0`.

  Recurring monthly charges are pro-rated by this so a panel opened on the 3rd
  reports three days of AgentMail rather than a month of it, and so the cost
  column can be read against sandbox hours, which are only ever accrued
  hours. A period entirely in the past is `1.0`.
  """
  @spec period_fraction(DateTime.t(), DateTime.t(), DateTime.t()) :: float()
  def period_fraction(period_start, period_end, now) do
    total = DateTime.diff(period_end, period_start, :second)
    elapsed = DateTime.diff(now, period_start, :second)

    cond do
      total <= 0 -> 1.0
      elapsed >= total -> 1.0
      elapsed <= 0 -> 0.0
      true -> elapsed / total
    end
  end
end
