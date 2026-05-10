defmodule FountainWeb.Live.BillingLive do
  @moduledoc """
  `/account/billing` — subscription status, trial countdown, monthly usage
  summary, and links to Stripe Checkout / Customer Portal.

  Accessible to all authenticated users regardless of subscription status
  (including `past_due` and `canceled`) so they can update payment details.
  """

  use FountainWeb, :live_view

  alias Fountain.Billing

  @impl true
  def mount(_params, _session, socket) do
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
  end

  @impl true
  def handle_event("manage_subscription", _params, socket) do
    user = socket.assigns.current_user
    socket = assign(socket, :stripe_url_loading, true)

    case build_stripe_url(user) do
      {:ok, url} ->
        {:noreply, redirect(socket, external: url)}

      {:error, _reason} ->
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
        <div class="rounded border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800" role="alert">
          Your subscription requires attention. Update your payment method to
          continue starting conversations.
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
                <%= format_status(@current_user.subscription_status) %>
              </span>
            </dd>
          </div>
          <%= if @current_user.subscription_status == "trialing" do %>
            <div class="flex items-center justify-between">
              <dt class="text-sm text-gray-500">Trial</dt>
              <dd class="text-sm font-medium">
                <%= trial_countdown_text(@current_user) %>
              </dd>
            </div>
          <% end %>
          <%= if @current_user.subscription_status == "active" do %>
            <div class="flex items-center justify-between">
              <dt class="text-sm text-gray-500">Billing period</dt>
              <dd class="text-sm font-medium">
                <%= Calendar.strftime(@period_start, "%B %-d") %> –
                <%= Calendar.strftime(@period_end, "%B %-d, %Y") %>
              </dd>
            </div>
          <% end %>
        </dl>

        <div class="mt-6">
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
        </div>
      </div>

      <%!-- Monthly usage summary --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium">Usage This Month</h2>
        <p class="mb-4 text-xs text-gray-400">
          <%= Calendar.strftime(@period_start, "%b %-d") %> –
          <%= Calendar.strftime(@period_end, "%b %-d, %Y") %>
        </p>
        <dl class="grid grid-cols-3 gap-4">
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Conversations</dt>
            <dd class="mt-1 text-2xl font-semibold"><%= @usage.conversations %></dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Turns</dt>
            <dd class="mt-1 text-2xl font-semibold"><%= @usage.turns %></dd>
          </div>
          <div class="rounded-md bg-gray-50 p-4 text-center">
            <dt class="text-xs text-gray-500">Sandbox-min</dt>
            <dd class="mt-1 text-2xl font-semibold"><%= format_minutes(@usage.sandbox_minutes) %></dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  # ─── Private helpers ───────────────────────────────────────────────────────────

  defp current_month_range do
    now = DateTime.utc_now()
    period_start = %DateTime{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    last_day = :calendar.last_day_of_the_month(now.year, now.month)
    period_end = %DateTime{now | day: last_day, hour: 23, minute: 59, second: 59, microsecond: {0, 0}}
    {period_start, period_end}
  end

  defp build_stripe_url(user) do
    return_url = FountainWeb.Endpoint.url() <> ~p"/account/billing"

    if user.subscription_status in ~w(active past_due) and user.stripe_customer_id do
      case Stripe.BillingPortal.Session.create(%{
             customer: user.stripe_customer_id,
             return_url: return_url
           }) do
        {:ok, session} -> {:ok, session.url}
        error -> error
      end
    else
      price_id = Application.get_env(:fountain, :stripe_price_id, "")

      base_params = %{
        mode: "subscription",
        line_items: [%{price: price_id, quantity: 1}],
        success_url: return_url <> "?checkout=success",
        cancel_url: return_url
      }

      params =
        if user.stripe_customer_id,
          do: Map.put(base_params, :customer, user.stripe_customer_id),
          else: Map.put(base_params, :customer_email, user.email)

      case Stripe.Checkout.Session.create(params) do
        {:ok, session} -> {:ok, session.url}
        error -> error
      end
    end
  end

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
