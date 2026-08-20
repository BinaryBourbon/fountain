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

  @impl true
  def mount(_params, _session, socket) do
    if Billing.enabled?() do
      user = socket.assigns.current_user
      {period_start, period_end} = current_month_range()
      usage = Billing.usage_summary(user.id, period_start, period_end)

      {:ok,
       assign(socket,
         page_title: "Billing",
         usage: usage,
         period_start: period_start,
         period_end: period_end,
         stripe_url_loading: false
       )}
    else
      {:ok, redirect(socket, to: ~p"/account")}
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
            <dd class="text-sm font-medium">Fountain</dd>
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
                {Calendar.strftime(@period_start, "%B %-d")} – {Calendar.strftime(
                  @period_end,
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

      <%!-- Monthly usage summary --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium">Usage This Month</h2>
        <p class="mb-4 text-xs text-gray-400">
          {Calendar.strftime(@period_start, "%b %-d")} – {Calendar.strftime(@period_end, "%b %-d, %Y")}
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
      </div>
    </div>
    """
  end

  # ─── Private helpers ───────────────────────────────────────────────────────────

  defp current_month_range, do: Billing.current_month_range()

  # Refused outright rather than relying on the button being hidden (#399):
  # a stale socket or a hand-sent event must not open Checkout for an
  # account whose subscriptions comp_account/1 deliberately cancelled.
  # Both surfaces mint the same URLs under the same rules, so the rules live in
  # the context (#524) rather than in a copy per surface.
  defp build_stripe_url(user), do: Billing.manage_url(user, billing_return_url())

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
end
