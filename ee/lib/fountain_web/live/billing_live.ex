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
         allowance: Billing.turn_hour_allowance(user, period: period),
         period: period,
         stripe_url_loading: false,
         plan: Billing.plan(user),
         sandbox_limit: Quotas.sandbox_limit_for(user),
         available_plans: Billing.available_plans()
       )}
    else
      {:ok, redirect(socket, to: ~p"/account")}
    end
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
          <div class="flex items-center justify-between">
            <dt class="text-sm text-gray-500">Plan</dt>
            <dd class="text-sm font-medium">{@plan.name}</dd>
          </div>
          <%!-- The number the plan is sold on, and the one an operator
                override can make differ from it — so show what is actually
                enforced rather than what the tier says. --%>
          <div class="flex items-center justify-between">
            <dt class="text-sm text-gray-500">Agents at once</dt>
            <dd class="text-sm font-medium">
              {@sandbox_limit}
              <span :if={@sandbox_limit != @plan.concurrent_sandboxes} class="text-gray-500">
                (adjusted for this account)
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
              {plan.included_turn_hours} turn hours included
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

      <%!-- Turn hours against the plan's allowance. Reported only; nothing
            refuses anything because a tenant is over it (#1016 step 4). --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <div class="flex items-baseline justify-between">
          <h2 class="text-lg font-medium">Turn hours</h2>
          <p class="text-sm tabular-nums">
            <span class="font-semibold">{format_hours(@allowance.used)}</span>
            <span class="text-gray-500">of {@allowance.included} included</span>
          </p>
        </div>
        <div class="mt-3 h-2 w-full overflow-hidden rounded-full bg-gray-100">
          <div
            class={[
              "h-full rounded-full",
              if(@allowance.over?, do: "bg-amber-500", else: "bg-indigo-500")
            ]}
            style={"width: #{meter_width(@allowance)}%"}
          >
          </div>
        </div>
        <p class="mt-3 text-xs text-gray-500">
          A turn hour is an hour with a prompt in flight. An agent sitting idle
          costs you nothing here, and neither does time on your own runner.
          Parked sandboxes are excluded from every number on this page.
        </p>
        <p :if={@allowance.over?} class="mt-2 text-xs text-amber-700">
          You are over the hours your plan includes. Nothing is limited and
          nothing extra is charged — we are showing you the number while we
          work out what a fair overage looks like.
        </p>
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

  defp format_hours(hours), do: hours |> Float.round(1) |> to_string()

  # Capped at 100 so an over-allowance account gets a full bar rather than one
  # that overflows its track. `over?` is what says it went past, not the width.
  # A plan with no hours (nothing sells one today) would divide by zero.
  defp meter_width(%{included: included}) when included <= 0, do: 0

  # `min/2` last and against a float: `min(101.5, 100)` returns the *integer*
  # 100, which Float.round/2 refuses — an over-allowance account 500s the page.
  defp meter_width(%{used: used, included: included}),
    do: (used / included * 100) |> Float.round(1) |> min(100.0)
end
