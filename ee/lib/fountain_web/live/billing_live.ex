defmodule FountainWeb.Live.BillingLive do
  @moduledoc """
  `/account/billing` — subscription status, trial countdown, monthly usage
  summary, and links to Stripe Checkout / Customer Portal.

  Accessible to all authenticated users regardless of subscription status
  (including `past_due` and `canceled`) so they can update payment details.

  Purely billing since #479: data export and account deletion live on the
  core `/account` page. On a billing-disabled instance this page does not
  exist — old bookmarks redirect to `/account`.
  """

  use FountainWeb, :live_view

  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Plans
  alias Fountain.Quotas

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      user = socket.assigns.current_user
      # The window Stripe invoices, not the calendar month — an allowance
      # measured over a period the customer is not charged for is worse than
      # no allowance. `:source` says which one this is; the template shows a
      # note when it is the fallback.
      period = Billing.billing_period(user)
      usage = Billing.usage_summary(user.id, period.start, period.end)

      {:ok,
       assign(socket,
         page_title: "Billing",
         usage: usage,
         period: period,
         # The prepaid balance (ADR 0030). `active?` false means the switch is
         # off and the card is not rendered at all.
         credits: Credits.summary(user),
         ledger: Credits.list_entries(user.id, limit: 10),
         stripe_url_loading: false,
         # Two plans, deliberately. `plan` is the tier the subscription names
         # — what Stripe charges for, what the picker highlights. `effective_plan`
         # is whose numbers apply today, which during a trial is the smaller
         # `trial` plan (`Plans.effective/1`).
         plan: Billing.plan(user),
         effective_plan: Plans.effective(user),
         # Whether subscribing actually moves a number. The trial ties the
         # cheapest tier on concurrency and hours, so for a Solo trialist
         # "raises those to 2 and 40" would be a sentence that says nothing.
         trial_raises_numbers?: trial_raises_numbers?(user),
         on_trial: user.subscription_status == "trialing" and Billing.enabled?(),
         sandbox_limit: Quotas.sandbox_limit_for(user),
         available_plans: Billing.available_plans()
       )}
    else
      {:ok, redirect(socket, to: ~p"/account")}
    end
  end

  # A trial is never *larger* than a paid plan, but since the caps were
  # retuned it can tie the cheapest one. Comparing rather than assuming is
  # what keeps the page from telling a Solo trialist that subscribing raises
  # their numbers to exactly the numbers they already have.
  defp trial_raises_numbers?(user) do
    tier = Plans.resolve(user.plan)
    now = Plans.effective(user)

    tier.included_turn_hours > now.included_turn_hours or
      tier.concurrent_sandboxes > now.concurrent_sandboxes
  end

  # Switching tier reprices the existing subscription rather than opening
  # Checkout, which would mint a second one. The new entitlement lands with
  # the webhook Stripe sends back, so the page says "applied shortly" instead
  # of showing a number the account does not have yet.
  @impl true
  def handle_event("change_plan", %{"plan" => slug}, socket) do
    user = socket.assigns.current_user

    case Billing.change_plan(user, slug, FountainWeb.Audited.attribution(socket)) do
      {:ok, _user} ->
        {:noreply,
         put_flash(
           socket,
           :info,
           "Switched to #{Plans.resolve(slug).name}. Your new limit applies shortly."
         )}

      {:error, :comped} ->
        {:noreply,
         put_flash(socket, :info, "This account is comped — there is no plan to change.")}

      # Nothing to reprice: an account whose subscription was cancelled, or one
      # that never had one. Checkout is the right door, and it is the button
      # already on this page.
      {:error, :no_subscription} ->
        {:noreply,
         put_flash(socket, :error, "Start a subscription first, then you can change plan.")}

      # The subscription holds a price this deployment does not recognise, so
      # there is nothing safe to reprice. In practice that means a price id
      # was removed from the config out from under a live subscription — most
      # likely `STRIPE_PRICE_ID`, which every `legacy` account still points
      # at. Saying "try again" would send them round a loop that cannot work.
      {:error, :plan_item_not_found} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "We could not match your subscription to a plan. Please contact support."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Unable to reach Stripe. Please try again.")}
    end
  end

  # A credit pack is a one-time Checkout (ADR 0030 decision 5). Stripe's
  # webhook grants it; the page reloads on return and shows the new balance.
  @impl true
  def handle_event("buy_credits", %{"cents" => cents}, socket) do
    user = socket.assigns.current_user
    socket = assign(socket, :stripe_url_loading, true)

    with {cents, ""} <- Integer.parse(to_string(cents)),
         {:ok, url} <- Credits.Purchases.checkout_url(user, cents, billing_return_url()) do
      {:noreply, redirect(socket, external: url)}
    else
      {:error, :subscription_required} ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:error, "Subscribe first, then you can buy credits.")}

      {:error, :comped} ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:info, "This account is comped — there is nothing to buy.")}

      _ ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:error, "Unable to reach Stripe. Please try again.")}
    end
  end

  @impl true
  def handle_event("manage_subscription", _params, socket) do
    user = socket.assigns.current_user
    socket = assign(socket, :stripe_url_loading, true)

    case build_stripe_url(user) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, :comped} ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:info, "This account is comped — there is nothing to pay.")}

      {:error, _reason} ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:error, "Unable to reach Stripe. Please try again.")}
    end
  end

  # Invoices live in the Stripe portal, and a canceled account still needs its
  # receipts — the Manage Subscription button no longer leads there once the
  # status leaves active/past_due, so this is the direct route. Portal always,
  # never Checkout: this must work for an account with no live subscription.
  @impl true
  def handle_event("billing_history", _params, socket) do
    user = socket.assigns.current_user
    socket = assign(socket, :stripe_url_loading, true)
    return_url = FountainWeb.Endpoint.url() <> ~p"/account/billing"

    case user.stripe_customer_id && Billing.portal_url(user, return_url) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      _ ->
        {:noreply,
         socket
         |> assign(:stripe_url_loading, false)
         |> put_flash(:error, "Unable to reach Stripe. Please try again.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl space-y-8 px-4 py-8">
      <h1 class="text-2xl font-semibold">Billing</h1>

      <%!-- past_due banner --%>
      <%= if @current_user.subscription_status == "past_due" do %>
        <div
          class="rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800"
          role="alert"
        >
          Your subscription requires attention. Update your payment method to
          continue starting conversations.
        </div>
      <% end %>

      <%!-- cancel-at-period-end notice: canceled in the portal, still inside
           the paid period. Access continues until the period ends. --%>
      <%= if canceling_at_period_end?(@current_user) do %>
        <div
          class="rounded border border-amber-300 bg-amber-50 px-4 py-3 text-sm text-amber-800"
          role="alert"
        >
          Your subscription is set to cancel — you keep full access until {access_until_text(
            @current_user
          )}. You can renew any time from
          Manage Subscription.
        </div>
      <% end %>

      <%!-- Subscription status card --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <h2 class="mb-4 text-lg font-medium">Subscription</h2>
        <dl class="space-y-3">
          <%!-- While a trial runs, `@plan` is the tier it converts into and
                `@effective_plan` is the smaller set of numbers in force. Both
                are named, because showing "Solo" beside Trial's two sandboxes
                is how a customer concludes the product is broken. --%>
          <div class="flex items-center justify-between">
            <dt class="text-sm text-gray-500">Plan</dt>
            <dd class="text-sm font-medium">
              <span :if={@on_trial}>Trial, then {@plan.name}</span>
              <span :if={!@on_trial}>{@plan.name}</span>
            </dd>
          </div>
          <%!-- The number the plan is sold on, and the one a trial or an
                operator override can make differ from it — so show what is
                actually enforced rather than what the tier says. --%>
          <div class="flex items-center justify-between">
            <dt class="text-sm text-gray-500">Agents at once</dt>
            <dd class="text-sm font-medium">
              {@sandbox_limit}
              <span
                :if={@sandbox_limit != @effective_plan.concurrent_sandboxes}
                class="text-gray-500"
              >
                (adjusted for this account)
              </span>
              <span
                :if={
                  @on_trial and @sandbox_limit == @effective_plan.concurrent_sandboxes and
                    @plan.concurrent_sandboxes > @effective_plan.concurrent_sandboxes
                }
                class="text-gray-500"
              >
                on trial, {@plan.concurrent_sandboxes} on {@plan.name}
              </span>
            </dd>
          </div>
          <div class="flex items-center justify-between">
            <dt class="text-sm text-gray-500">Status</dt>
            <dd>
              <span class={[
                "inline-flex items-center rounded-full px-2.5 py-0.5 text-xs font-medium",
                status_badge_class(@current_user.subscription_status)
              ]}>
                {format_status(@current_user.subscription_status)}
              </span>
            </dd>
          </div>
          <%= if @current_user.subscription_status == "trialing" do %>
            <div class="flex items-center justify-between">
              <dt class="text-sm text-gray-500">Trial</dt>
              <dd class="text-sm font-medium">
                {trial_countdown_text(@current_user)}
              </dd>
            </div>
          <% end %>
          <%= if canceling_at_period_end?(@current_user) do %>
            <div class="flex items-center justify-between">
              <dt class="text-sm text-gray-500">Access until</dt>
              <dd class="text-sm font-medium">
                {access_until_text(@current_user)}
              </dd>
            </div>
          <% end %>
          <%= if @current_user.subscription_status == "active" do %>
            <div class="flex items-center justify-between">
              <dt class="text-sm text-gray-500">Billing period</dt>
              <dd class="text-sm font-medium">
                {Calendar.strftime(@period.start, "%B %-d")} – {Calendar.strftime(
                  @period.end,
                  "%B %-d, %Y"
                )}
              </dd>
            </div>
          <% end %>
        </dl>

        <div class="mt-6 flex items-center gap-4">
          <%!-- A comped account must not be offered Checkout (#399):
               comp_account/1 cancels the live subscriptions, so the routing
               below reads the account as a fresh customer, Checkout charges
               them, and the webhook adoption ignores the subscription — a
               paying customer the app knows nothing about. --%>
          <%= if @current_user.subscription_status == "comped" do %>
            <span class="text-sm text-zinc-600">
              This account is comped — no payment needed.
            </span>
          <% else %>
            <button
              phx-click="manage_subscription"
              disabled={@stripe_url_loading}
              class="rounded-md bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:cursor-not-allowed disabled:opacity-50"
            >
              <%= if @current_user.subscription_status in ~w(active past_due) do %>
                Manage Subscription
              <% else %>
                Upgrade
              <% end %>
            </button>
          <% end %>
          <%!-- Invoices live in the portal. Manage Subscription already leads
               there for active/past_due; every other status with a Stripe
               customer (canceled above all — they paid, they need receipts)
               gets a direct route. --%>
          <%= if @current_user.stripe_customer_id &&
                   @current_user.subscription_status not in ~w(active past_due) do %>
            <button
              phx-click="billing_history"
              disabled={@stripe_url_loading}
              class="text-sm font-medium text-indigo-600 hover:text-indigo-700 disabled:cursor-not-allowed disabled:opacity-50"
            >
              Billing history &amp; invoices
            </button>
          <% end %>
        </div>
      </div>

      <%!-- Plan picker. Shown only to an account with a subscription to
            reprice and only when this deployment has more than one plan
            priced: with nothing to switch between it is a card of disabled
            buttons. A comped account never sees it — an operator's decision
            is not the customer's to change. --%>
      <div
        :if={plan_picker?(@current_user, @available_plans)}
        class="rounded-lg border bg-white p-6 shadow-sm"
      >
        <h2 class="text-lg font-medium">Change plan</h2>
        <p class="mt-1 text-sm text-gray-500">
          Plans differ by how many sandboxes you can run at the same time,
          and by the turn hours that come with them.
          Upgrades take effect immediately and are prorated; downgrades apply
          from your next invoice.
        </p>

        <div class="mt-5 grid gap-4 sm:grid-cols-3">
          <div
            :for={plan <- @available_plans}
            class={[
              "rounded-lg border p-4",
              if(plan.slug == @plan.slug, do: "border-indigo-500 bg-indigo-50", else: "bg-white")
            ]}
          >
            <div class="flex items-baseline justify-between">
              <h3 class="text-sm font-semibold">{plan.name}</h3>
              <span class="text-sm font-medium">{Plans.format_usd(plan.monthly_cents)}</span>
            </div>
            <p class="mt-1 text-xs text-gray-500">
              {plan.concurrent_sandboxes} agents at once
            </p>
            <p class="mt-0.5 text-xs text-gray-500">
              {Credits.format_cents(plan.included_turn_hours * Credits.price_card().turn_hour)} of credit a month
            </p>
            <div class="mt-3">
              <span :if={plan.slug == @plan.slug} class="text-xs font-medium text-indigo-700">
                Current plan
              </span>
              <button
                :if={plan.slug != @plan.slug}
                phx-click="change_plan"
                phx-value-plan={plan.slug}
                data-confirm={"Switch to #{plan.name} at #{Plans.format_usd(plan.monthly_cents)}/mo?"}
                class="text-xs font-medium text-indigo-600 hover:text-indigo-700"
              >
                {if Plans.upgrade?(@plan, plan), do: "Upgrade", else: "Switch"} to {plan.name}
              </button>
            </div>
          </div>
        </div>

        <p :if={not @plan.public?} class="mt-4 text-xs text-gray-500">
          You are on {@plan.name}, an earlier plan we no longer sell. You can
          keep it for as long as you like — moving to one of the plans above is
          a one-way change.
        </p>
      </div>

      <%!-- Prepaid credits (ADR 0030). Shown only once burning has started on
            this deployment. Nothing refuses anything at zero yet (phase 4). --%>
      <div :if={@credits.active?} class="rounded-lg border bg-white p-6 shadow-sm" id="credits">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-medium">Credits</h2>
          <p class="text-sm tabular-nums">
            <span class={[
              "font-semibold",
              @credits.balance_cents < 0 && "text-amber-700"
            ]}>
              {Credits.format_cents(@credits.balance_cents)}
            </span>
            <span class="text-gray-500">remaining</span>
          </p>
        </div>
        <p class="mt-3 text-xs text-gray-500">
          Conversation time costs {Credits.format_cents(@credits.turn_hour_cents)} per turn hour
          and comes out of this balance. Your plan puts {Credits.format_cents(
            Plans.included_turn_hours(@current_user) * @credits.turn_hour_cents
          )} in at the start of every billing period; what is unused expires with the period.
          Credits you buy never expire and are spent last.
        </p>
        <p :if={@credits.expires_at} class="mt-2 text-xs text-gray-500">
          {Credits.format_cents(@credits.expiring_cents)} of this expires on {Calendar.strftime(
            @credits.expires_at,
            "%b %-d"
          )}.
          <span :if={@credits.purchased_cents > 0}>
            {Credits.format_cents(@credits.purchased_cents)} is money you bought and keeps.
          </span>
        </p>
        <p :if={@credits.balance_cents < 0} class="mt-2 text-xs text-amber-700">
          Your balance is below zero. Nothing is limited yet; the next grant or purchase
          brings it back up.
        </p>
        <div
          :if={@current_user.subscription_status in ~w(active past_due)}
          class="mt-4 flex flex-wrap items-center gap-2"
        >
          <button
            :for={cents <- Credits.packs()}
            phx-click="buy_credits"
            phx-value-cents={cents}
            disabled={@stripe_url_loading}
            class="rounded-md border border-indigo-600 px-3 py-1.5 text-sm font-medium text-indigo-700 hover:bg-indigo-50 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Buy {Credits.format_cents(cents)}
          </button>
          <span class="text-xs text-gray-500">One-time payment. Never expires.</span>
        </div>
        <p
          :if={@current_user.subscription_status == "trialing"}
          class="mt-4 text-xs text-gray-500"
        >
          Subscribe to buy credits. Your trial credit is what you have until then.
        </p>
        <table :if={@ledger != []} class="mt-4 w-full text-xs">
          <thead class="text-left text-gray-500">
            <tr>
              <th class="py-1 font-normal">When</th>
              <th class="py-1 font-normal">What</th>
              <th class="py-1 text-right font-normal">Amount</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={entry <- @ledger} class="border-t">
              <td class="py-1 tabular-nums text-gray-500">
                {Calendar.strftime(entry.inserted_at, "%b %-d")}
              </td>
              <td class="py-1">{ledger_label(entry)}</td>
              <td class={[
                "py-1 text-right tabular-nums",
                entry.amount_cents < 0 && "text-gray-500"
              ]}>
                {Credits.format_cents(entry.amount_cents)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>

      <%!-- Usage over the billing period --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium">Usage this period</h2>
        <p class="mb-4 text-xs text-gray-400">
          {Calendar.strftime(@period.start, "%b %-d")} – {Calendar.strftime(@period.end, "%b %-d, %Y")}
          <span :if={@period.source == :calendar_month}>
            · calendar month (we do not have an invoiced period for this account yet)
          </span>
        </p>
        <dl class="grid grid-cols-3 gap-4">
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Conversations</dt>
            <dd class="mt-1 text-2xl font-semibold">{@usage.conversations}</dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Turns</dt>
            <dd class="mt-1 text-2xl font-semibold">{@usage.turns}</dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Sandbox-min</dt>
            <dd class="mt-1 text-2xl font-semibold">{format_minutes(@usage.sandbox_minutes)}</dd>
          </div>
        </dl>
        <p :if={@usage.sandbox_minutes_by_provider != %{}} class="mt-3 text-xs text-gray-500">
          Sandbox minutes by provider
          <span
            :for={{provider, minutes} <- Enum.sort(@usage.sandbox_minutes_by_provider)}
            class="ml-2 inline-block rounded bg-gray-100 px-1.5 py-0.5 tabular-nums"
          >
            <span class="font-medium text-gray-700">{provider}</span> {format_minutes(minutes)}
          </span>
        </p>
      </div>
    </div>
    """
  end

  # ─── Private helpers ───────────────────────────────────────────────────────────

  # Refused outright rather than relying on the button being hidden (#399):
  # a stale socket or a hand-sent event must not open Checkout for an
  # account whose subscriptions comp_account/1 deliberately cancelled.
  # Both surfaces mint the same URLs under the same rules, so the rules live in
  # the context (#524) rather than in a copy per surface.
  defp build_stripe_url(user), do: Billing.manage_url(user, billing_return_url())

  # Three conditions, all of them things the picker cannot work without: a
  # subscription to reprice, a status that is the customer's to change, and
  # more than one plan priced on this deployment.
  defp plan_picker?(user, available_plans) do
    user.subscription_status != "comped" and
      user.stripe_subscription_id not in [nil, ""] and
      length(available_plans) > 1
  end

  defp billing_return_url, do: FountainWeb.Endpoint.url() <> ~p"/account/billing"

  # Only an active subscription can be pending cancellation; once `.deleted`
  # lands the status is canceled and the flag is cleared by the sync.
  defp canceling_at_period_end?(user) do
    user.subscription_status == "active" and user.cancel_at_period_end
  end

  defp access_until_text(%{current_period_end: %DateTime{} = ends_at}) do
    Calendar.strftime(ends_at, "%B %-d, %Y")
  end

  defp access_until_text(_), do: "the end of the current billing period"

  defp trial_countdown_text(%{trial_ends_at: nil}), do: "Trial active"

  defp trial_countdown_text(%{trial_ends_at: ends_at}) do
    diff = DateTime.diff(ends_at, DateTime.utc_now(), :second)
    days = max(0, div(diff, 86_400))

    case days do
      0 -> "Trial ends today"
      1 -> "1 day remaining"
      n -> "#{n} days remaining"
    end
  end

  defp format_status("trialing"), do: "Trial"
  defp format_status("active"), do: "Active"
  defp format_status("past_due"), do: "Past due"
  defp format_status("canceled"), do: "Canceled"
  defp format_status(s), do: String.capitalize(s || "Unknown")

  defp status_badge_class("comped"), do: "bg-purple-100 text-purple-800"
  defp status_badge_class("trialing"), do: "bg-blue-100 text-blue-800"
  defp status_badge_class("active"), do: "bg-green-100 text-green-800"
  defp status_badge_class("past_due"), do: "bg-red-100 text-red-800"
  defp status_badge_class("canceled"), do: "bg-gray-100 text-gray-600"
  defp status_badge_class(_), do: "bg-gray-100 text-gray-600"

  defp format_minutes(minutes) do
    minutes
    |> Float.round(1)
    |> to_string()
  end

  defp ledger_label(%{reason: "grant_tier", metadata: %{"plan" => plan}}),
    do: "#{String.capitalize(plan)} plan credit"

  defp ledger_label(%{reason: "grant_tier"}), do: "Plan credit"
  defp ledger_label(%{reason: "grant_trial"}), do: "Trial credit"
  defp ledger_label(%{reason: "grant_admin"}), do: "Credit from Fountain"
  defp ledger_label(%{reason: "purchase"}), do: "Purchase"

  defp ledger_label(%{reason: "burn_turn", metadata: %{"turn_seconds" => s}}),
    do: "Conversation time, #{format_seconds(s)}"

  defp ledger_label(%{reason: "burn_turn"}), do: "Conversation time"
  defp ledger_label(%{reason: "burn_rent"}), do: "Number or inbox, one month"
  defp ledger_label(%{reason: "burn_message"}), do: "Message"
  defp ledger_label(%{reason: "expire"}), do: "Expired with the period"
  defp ledger_label(%{reason: "clawback_" <> _}), do: "Refund reversed"
  defp ledger_label(%{reason: reason}), do: reason

  defp format_seconds(s) when is_integer(s) and s < 60, do: "#{s}s"
  defp format_seconds(s) when is_integer(s) and s < 3600, do: "#{div(s, 60)}m"
  defp format_seconds(s) when is_integer(s), do: "#{Float.round(s / 3600, 1)}h"
end
