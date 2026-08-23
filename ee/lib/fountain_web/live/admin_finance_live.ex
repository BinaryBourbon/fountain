defmodule FountainWeb.Live.AdminFinanceLive do
  @moduledoc """
  `/admin/finance` — what Fountain is paid, what Fountain pays, and the gap,
  per tenant.

  `/admin` had both halves and never put them together: an MRR tile with no
  cost beside it, and a sandbox-hours table with no money in it. Neither could
  answer the only question an operator actually asks a finance page, which is
  which accounts cost more than they bring in.

  Three things this page is careful about, because each has a way of lying:

    * **It shows no money it was not told.** The rate card
      (`Fountain.Billing.Finance.rate_card/0`) is config, and an unpriced line
      renders as `—`, never as `$0.00`. A deployment that has set nothing sees
      hours, inboxes, numbers and message counts — a complete report in the
      units it does know.
    * **It does not assume which hours the provider bills.** Cost prices either
      every hour a sandbox was awake or only the hours with a prompt in
      flight, and the toggle switches between them. Which one is right is a
      fact about the provider's invoice rather than about this codebase, so
      the page offers both and labels the one it is on. Active hours and turn
      hours sit on every row either way, because the gap between them is idle
      time and that is the lever on the bill.
    * **The window is one calendar month for everybody.** Per-tenant invoiced
      periods each start on a different day, and a total over windows like
      that is not a number that can be held next to a provider invoice. A
      tenant's own invoiced period stays on their detail page.

  Read-only. Every lever stays on `/admin` next to its confirmation.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Billing
  alias Fountain.Billing.Finance
  alias Fountain.Billing.SandboxUsage

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 30_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Finance")
     |> assign(:billing_enabled, Billing.enabled?())
     |> assign(:contacts_billed?, Finance.contacts_billed?())
     |> assign(:months_ago, 0)
     |> assign(:basis, Finance.default_basis())
     |> assign_finance()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    months_ago =
      case params["months_ago"] do
        raw when is_binary(raw) ->
          case Integer.parse(raw) do
            {n, ""} when n >= 0 and n <= 11 -> n
            _ -> 0
          end

        _ ->
          0
      end

    {:noreply,
     socket
     |> assign(:months_ago, months_ago)
     |> assign(:basis, parse_basis(params["basis"]))
     |> assign_finance()}
  end

  # Both names are honoured, because the toggle emits both: a link reading
  # "active hours" has to select active even where the deployment default is
  # turn. Anything else falls back to the default rather than to `:active`, so
  # a mistyped URL does not quietly show a self-hoster the wrong basis.
  defp parse_basis("turn"), do: :turn
  defp parse_basis("active"), do: :active
  defp parse_basis(_), do: Finance.default_basis()

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    {:noreply, assign_finance(socket)}
  end

  # Heavier than the /admin refresh (a full attribution pass plus four grouped
  # queries), so it runs on 30s rather than 10s, and a closed month is not
  # recomputed at all — nothing in it can change.
  defp assign_finance(socket) do
    assign(
      socket,
      :finance,
      Finance.summary(
        period: month_range(socket.assigns.months_ago),
        basis: socket.assigns.basis
      )
    )
  end

  # `months_ago` back from the current month, as a whole UTC month. Zero is
  # the running month, which is the default and the only one still moving.
  defp month_range(0), do: Billing.current_month_range()

  defp month_range(months_ago) do
    now = DateTime.utc_now()
    total = now.year * 12 + (now.month - 1) - months_ago
    {year, month} = {div(total, 12), rem(total, 12) + 1}

    start = %DateTime{
      now
      | year: year,
        month: month,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
        microsecond: {0, 0}
    }

    %DateTime{
      start
      | day: :calendar.last_day_of_the_month(year, month),
        hour: 23,
        minute: 59,
        second: 59
    }
    |> then(&{start, &1})
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <.admin_tabs current={:finance} billing_enabled={@billing_enabled} />
        <h1 class="text-2xl font-semibold mt-4">Finance</h1>
        <p class="text-sm text-zinc-500 mt-1">
          Revenue against platform spend, per tenant, for {Calendar.strftime(
            @finance.period_start,
            "%B %Y"
          )}. {if @months_ago == 0,
            do: "The month so far; refreshes every 30s.",
            else: "A closed month."}
        </p>
        <div class="flex flex-wrap gap-2 mt-3">
          <.link
            :for={n <- 0..5}
            patch={~p"/admin/finance?months_ago=#{n}&basis=#{@basis}"}
            class={[
              "rounded border px-2 py-1 text-xs",
              if(@months_ago == n,
                do: "bg-zinc-900 text-white border-zinc-900",
                else: "bg-white text-zinc-600 border-zinc-200 hover:border-zinc-400"
              )
            ]}
          >
            {month_label(n)}
          </.link>
        </div>
        <%!-- Which hours a provider rate multiplies is a fact about their
              invoice, and the only way to settle it is to try both and see
              which total lands. So it is a toggle, not a constant. --%>
        <div class="flex flex-wrap items-center gap-2 mt-2 text-xs">
          <span class="text-zinc-500">Charge sandbox hours as</span>
          <.link
            :for={b <- Finance.bases()}
            patch={~p"/admin/finance?months_ago=#{@months_ago}&basis=#{b}"}
            class={[
              "rounded border px-2 py-1",
              if(@basis == b,
                do: "bg-zinc-900 text-white border-zinc-900",
                else: "bg-white text-zinc-600 border-zinc-200 hover:border-zinc-400"
              )
            ]}
          >
            {basis_label(b)}
          </.link>
        </div>
      </div>

      <%!-- The whole page's honesty depends on this being visible when it
            applies: without a rate card the cost columns are hours and units,
            not dollars, and a reader who assumes otherwise reads every `—` as
            a zero. --%>
      <div
        :if={not @finance.priced?}
        class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-sm text-amber-900 space-y-1"
      >
        <div class="font-medium">No rate card is configured, so there is no cost in dollars.</div>
        <div class="text-xs">
          Hours, inboxes, numbers and messages below are real. Set <code>PROVIDER_HOURLY_CENTS</code>, <code>AGENTMAIL_INBOX_CENTS</code>, <code>AGENTPHONE_NUMBER_CENTS</code>,
          <code>AGENTMAIL_MESSAGE_CENTS</code>
          and <code>AGENTPHONE_MESSAGE_CENTS</code>
          to price them. An unpriced line stays <code>—</code>; it never becomes $0.
        </div>
      </div>

      <%!-- ── The three numbers, and the one that matters ── --%>
      <section class="grid grid-cols-2 lg:grid-cols-4 gap-3">
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">MRR</div>
          <div class="text-2xl font-semibold tabular-nums">
            {money(@finance.revenue.mrr_cents)}
          </div>
          <div class="text-xs text-zinc-500">
            active subscriptions, priced per plan
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Platform cost</div>
          <div class="text-2xl font-semibold tabular-nums">{money(total_cost(@finance))}</div>
          <div class="text-xs text-zinc-500">
            sandboxes · contacts · messages
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Gross margin</div>
          <div class={[
            "text-2xl font-semibold tabular-nums",
            negative?(gross_margin(@finance)) && "text-red-700"
          ]}>
            {money(gross_margin(@finance))}
          </div>
          <div class="text-xs text-zinc-500">
            {margin_pct(@finance) || "no rate card"}
          </div>
        </div>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
          <div class="text-xs text-zinc-500">Turn hours used / sold</div>
          <div class="text-2xl font-semibold tabular-nums">
            {Float.round(@finance.turn_hours.used, 1)}
            <span class="text-base text-zinc-400">/ {@finance.turn_hours.sold}</span>
          </div>
          <div class="text-xs text-zinc-500">
            {if @finance.turn_hours.utilization,
              do: "#{round(@finance.turn_hours.utilization * 100)}% of the allowance sold",
              else: "nothing sold"}
            <span :if={@finance.turn_hours.over_allowance > 0} class="text-amber-700">
              · {@finance.turn_hours.over_allowance} over
            </span>
          </div>
        </div>
      </section>

      <%!-- ── Revenue ── --%>
      <section :if={@billing_enabled} class="space-y-3">
        <h2 class="text-lg font-medium">Revenue</h2>
        <div :if={@finance.revenue.by_plan == []} class="text-sm text-zinc-500">
          No active subscriptions.
        </div>
        <table
          :if={@finance.revenue.by_plan != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">Plan</th>
              <th class="px-4 py-2 text-right">Accounts</th>
              <th class="px-4 py-2 text-right">Plan MRR</th>
              <th class="px-4 py-2 text-right">Contact add-on</th>
              <th class="px-4 py-2 text-right">Total</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={line <- @finance.revenue.by_plan} class="border-b border-zinc-100">
              <td class="px-4 py-2">
                {line.plan.name}
                <span class="text-xs text-zinc-400">
                  {Fountain.Plans.format_usd(line.plan.monthly_cents)}/mo · {line.plan.included_turn_hours}h
                </span>
              </td>
              <td class="px-4 py-2 text-right tabular-nums">{line.accounts}</td>
              <td class="px-4 py-2 text-right tabular-nums">{money(line.plan_cents)}</td>
              <td class="px-4 py-2 text-right tabular-nums">{money(line.contact_cents)}</td>
              <td class="px-4 py-2 text-right tabular-nums font-medium">
                {money(line.plan_cents + line.contact_cents)}
              </td>
            </tr>
          </tbody>
          <tfoot class="border-t border-zinc-200 font-medium">
            <tr>
              <td class="px-4 py-2" colspan="4">MRR</td>
              <td class="px-4 py-2 text-right tabular-nums">
                {money(@finance.revenue.mrr_cents)}
              </td>
            </tr>
          </tfoot>
        </table>
        <%!-- A bare $0.00 in the add-on column next to a page that also
              reports real inboxes and numbers reads as "nobody has contacts".
              It usually means the opposite: they have them and nothing bills
              for them. --%>
        <div
          :if={not @contacts_billed?}
          class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-xs text-amber-900"
        >
          <span class="font-medium">Teammate contacts are not billed on this deployment.</span>
          The add-on column is $0 by configuration, not because nobody holds one — the cost
          section below still counts every inbox and number, because we pay for those either way.
          Set <code>STRIPE_PRICE_ID_CONTACT</code>
          to start charging. It puts a line item on the next invoice of every tenant who already
          holds contacts, so tell them first.
        </div>
        <div class="text-xs text-zinc-500 space-x-3">
          <span title="What past_due accounts would bill at their current plan — revenue that has not arrived.">
            At risk (past_due):
            <span class="tabular-nums">{money(@finance.revenue.at_risk_cents)}</span>
          </span>
          <span title="What trialing accounts will bill if they convert.">
            · In trial: <span class="tabular-nums">{money(@finance.revenue.trialing_cents)}</span>
          </span>
          <span title="What comped accounts would bill — the size of the discount, and it is not revenue.">
            · Comped: <span class="tabular-nums">{money(@finance.revenue.comped_cents)}</span>
          </span>
        </div>
      </section>

      <%!-- ── Cost ── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-medium">Cost</h2>
        <div class="grid grid-cols-2 lg:grid-cols-3 gap-3">
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Sandboxes</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.cost.sandbox_cents)}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {format_hours(billed_hours(@finance))} {basis_label(@basis)}, on providers we pay
            </div>
            <div
              :if={@basis == :active and @finance.cost.idle_hours > 0}
              class="text-xs tabular-nums text-amber-700"
            >
              {format_hours(@finance.cost.idle_hours)} of it idle
              <span :if={@finance.cost.idle_cents}>
                — {money(@finance.cost.idle_cents)} a shorter timeout would remove
              </span>
            </div>
            <div :if={@basis == :turn} class="text-xs text-zinc-400 tabular-nums">
              {format_hours(@finance.cost.active_hours)} awake in total; the idle part is charged
              at nothing on this basis
            </div>
          </div>
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Contacts (AgentMail · AgentPhone)</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.cost.contact_cents)}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {@finance.cost.inboxes} {pluralize(@finance.cost.inboxes, "inbox", "inboxes")} · {@finance.cost.numbers} {pluralize(
                @finance.cost.numbers,
                "number",
                "numbers"
              )}
            </div>
            <div class="text-xs text-zinc-400">
              monthly, pro-rated to {round(@finance.period_fraction * 100)}% of the month
            </div>
          </div>
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Messages</div>
            <div class="text-xl font-semibold tabular-nums">
              {money(@finance.cost.message_cents)}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {@finance.cost.emails_sent} email · {@finance.cost.sms_sent} SMS out · {@finance.cost.sms_received} SMS in
            </div>
            <div class="text-xs text-zinc-400">inbound counts — AgentPhone charges to receive</div>
          </div>
        </div>

        <div :if={@finance.cost.by_provider != %{}} class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div
            :for={{provider, totals} <- Enum.sort(@finance.cost.by_provider)}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3"
          >
            <div class="text-xs text-zinc-500">{provider}</div>
            <div class="text-lg font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(totals.active_seconds))}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {rate_label(@finance.rate_card, provider)}
            </div>
            <div :if={not SandboxUsage.platform_cost?(provider)} class="text-xs text-zinc-400">
              tenant hardware, not our bill
            </div>
          </div>
        </div>

        <div :if={@finance.unattributed_cost_cents not in [nil, 0]} class="text-xs text-zinc-500">
          {money(@finance.unattributed_cost_cents)} of that belongs to deleted accounts and is in
          no tenant row below — spend nobody can be charged for.
        </div>
      </section>

      <%!-- ── The row that matters ── --%>
      <section class="space-y-3">
        <h2 class="text-lg font-medium">Per tenant ({length(@finance.tenants)})</h2>
        <p class="text-xs text-zinc-500">
          Worst margin first. <strong>Active hours</strong>
          is what a provider charges for; <strong>turn hours</strong>
          is the part with a prompt in flight, which is what the plan includes. The gap is idle time.
        </p>
        <div class="overflow-x-auto">
          <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
            <thead class="text-left text-zinc-500 border-b border-zinc-200">
              <tr>
                <th class="px-3 py-2">Account</th>
                <th class="px-3 py-2">Plan</th>
                <th class="px-3 py-2 text-right">Revenue</th>
                <th
                  class="px-3 py-2 text-right"
                  title="Turn hours used against the plan's included hours"
                >
                  Turn h
                </th>
                <th
                  class="px-3 py-2 text-right"
                  title="Active sandbox hours — what providers charge for"
                >
                  Active h
                </th>
                <th class="px-3 py-2 text-right">Contacts</th>
                <th class="px-3 py-2 text-right">Msgs</th>
                <th class="px-3 py-2 text-right">Cost</th>
                <th class="px-3 py-2 text-right">Margin</th>
              </tr>
            </thead>
            <tbody>
              <tr :if={@finance.tenants == []}>
                <td colspan="9" class="px-3 py-6 text-center text-sm text-zinc-500">No accounts.</td>
              </tr>
              <tr
                :for={t <- @finance.tenants}
                class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50"
              >
                <td class="px-3 py-2 font-mono text-xs">
                  <.link navigate={~p"/admin/users/#{t.user_id}"} class="hover:underline">
                    {t.email}
                  </.link>
                  <span class={[
                    "ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                    subscription_status_color(t.subscription_status)
                  ]}>
                    {t.subscription_status}
                  </span>
                </td>
                <%!-- Both plans, when they differ: the trial's numbers are
                      what the allowance column is measured against, and the
                      tier is what converting would bill. Showing only one of
                      them makes the other column look wrong. --%>
                <td class="px-3 py-2 text-xs">{plan_label(t)}</td>
                <td class="px-3 py-2 text-right tabular-nums text-xs">
                  {money(t.revenue_cents)}
                  <div :if={t.contact_revenue_cents > 0} class="text-zinc-400">
                    incl. {money(t.contact_revenue_cents)} contacts
                  </div>
                </td>
                <td class={[
                  "px-3 py-2 text-right tabular-nums text-xs",
                  t.allowance_used && t.allowance_used > 1.0 && "text-amber-700 font-medium"
                ]}>
                  {Float.round(t.turn_hours, 1)}
                  <span class="text-zinc-400">/ {t.included_turn_hours}</span>
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs">
                  {Float.round(t.active_hours, 1)}
                  <div :if={t.idle_hours > 0} class="text-zinc-400">
                    {Float.round(t.idle_hours, 1)} idle
                  </div>
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs text-zinc-500">
                  {contacts_cell(t)}
                </td>
                <td
                  class="px-3 py-2 text-right tabular-nums text-xs text-zinc-500"
                  title={"#{t.emails_sent} email · #{t.sms_sent} SMS out · #{t.sms_received} SMS in"}
                >
                  {t.emails_sent + t.sms_sent + t.sms_received}
                </td>
                <td class="px-3 py-2 text-right tabular-nums text-xs" title={cost_breakdown(t)}>
                  {money(t.cost_cents)}
                </td>
                <td class={[
                  "px-3 py-2 text-right tabular-nums text-xs font-medium",
                  negative?(t.margin_cents) && "text-red-700"
                ]}>
                  {money(t.margin_cents)}
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </div>
    """
  end

  ## ── formatting ────────────────────────────────────────────────────────────

  # `nil` is "we were not told", and it must not render as a number. Every
  # money cell on this page goes through here for that reason.
  defp money(nil), do: "—"

  # Rates are fractional cents (#1029) and a cost total is whole ones. Every
  # cost path rounds before it gets here, but a float reaching this function
  # must round rather than raise: a 500 on the finance page is a worse answer
  # than a cent of rounding, and that is exactly what shipped — `rate_label/2`
  # handed `money/1` a raw `10.76` and took the whole page down the moment a
  # rate card was configured.
  defp money(cents) when is_float(cents), do: money(round(cents))

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs = abs(cents)
    "#{sign}$#{div(abs, 100)}.#{String.pad_leading(to_string(rem(abs, 100)), 2, "0")}"
  end

  defp negative?(cents), do: is_integer(cents) and cents < 0

  defp total_cost(%{cost: cost}) do
    [cost.sandbox_cents, cost.contact_cents, cost.message_cents]
    |> then(fn parts -> if Enum.any?(parts, &is_nil/1), do: nil, else: Enum.sum(parts) end)
  end

  defp gross_margin(finance) do
    case total_cost(finance) do
      nil -> nil
      cost -> finance.revenue.mrr_cents - cost
    end
  end

  defp margin_pct(finance) do
    mrr = finance.revenue.mrr_cents

    case gross_margin(finance) do
      nil -> nil
      _ when mrr <= 0 -> "no revenue to divide"
      margin -> "#{round(margin / mrr * 100)}% of MRR"
    end
  end

  # A rate is not a total, and rounding it to whole cents throws away the part
  # that matters: 10.76c/hr and 5.45c/hr both render as "$0.11" and "$0.05"
  # once, and as the same "$0.05" for anything between 4.5 and 5.5. Rates are
  # shown in cents, with their fraction.
  defp rate_label(card, provider) do
    cond do
      not SandboxUsage.platform_cost?(provider) -> "no cost to us"
      rate = Map.get(card.providers, provider) -> "#{trim_zeros(rate)}c/hour"
      true -> "no rate configured"
    end
  end

  # `10.76` renders as "10.76", `2.0` as "2" — a whole rate should not grow a
  # decimal point just because the config parser returns a float.
  defp trim_zeros(rate) when is_integer(rate), do: Integer.to_string(rate)

  defp trim_zeros(rate) when is_float(rate) do
    if rate == Float.round(rate), do: Integer.to_string(trunc(rate)), else: to_string(rate)
  end

  defp contacts_cell(%{inboxes: 0, numbers: 0}), do: "—"
  defp contacts_cell(%{inboxes: n, numbers: n}), do: "#{n}✉ #{n}☎"
  defp contacts_cell(%{inboxes: i, numbers: n}), do: "#{i}✉ #{n}☎"

  defp cost_breakdown(t) do
    "sandboxes #{money(t.sandbox_cost_cents)} · contacts #{money(t.contact_cost_cents)} · messages #{money(t.message_cost_cents)}"
  end

  defp pluralize(1, singular, _plural), do: singular
  defp pluralize(_n, _singular, plural), do: plural

  defp plan_label(%{plan: plan, effective_plan: plan}), do: plan.name

  defp plan_label(%{plan: plan, effective_plan: effective}),
    do: "#{effective.name} → #{plan.name}"

  defp basis_label(:active), do: "active hours"
  defp basis_label(:turn), do: "turn hours"

  # The hours the reported cost was actually computed from, so the tile's
  # subtitle cannot claim one basis while its number came from the other.
  defp billed_hours(%{cost: cost, turn_hours: turn_hours}) do
    case cost.basis do
      :turn -> turn_hours.used
      :active -> cost.active_hours
    end
  end

  defp month_label(0), do: "This month"
  defp month_label(1), do: "Last month"
  defp month_label(n), do: "#{n} months ago"
end
