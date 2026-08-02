defmodule FountainWeb.Live.BillingLive do
  @moduledoc """
  `/account/billing` — subscription status, trial countdown, monthly usage
  summary, and links to Stripe Checkout / Customer Portal.

  Accessible to all authenticated users regardless of subscription status
  (including `past_due` and `canceled`) so they can update payment details.
  """

  use FountainWeb, :live_view

  alias Fountain.Accounts.Deletion
  alias Fountain.Billing
  alias Fountain.Exports

  @impl true
  def mount(_params, _session, socket) do
    socket = FountainWeb.Audited.put_client_ip(socket)
    user = socket.assigns.current_user
    {period_start, period_end} = current_month_range()
    usage = Billing.usage_summary(user.id, period_start, period_end)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(Fountain.PubSub, Exports.topic(user.id))
    end

    {:ok,
     assign(socket,
       page_title: "Billing",
       usage: usage,
       period_start: period_start,
       period_end: period_end,
       stripe_url_loading: false,
       delete_confirmation: "",
       deleting: false,
       export: Exports.latest_export(user.id)
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
  def handle_event("request_export", _params, socket) do
    user = socket.assigns.current_user

    case Exports.request_export(user, actor: "self", request_ip: socket.assigns[:client_ip]) do
      {:ok, export} ->
        {:noreply,
         socket
         |> assign(:export, export)
         |> put_flash(:info, "Export started — the download will appear here when it is ready.")}

      {:error, {:rate_limited, retry_after}} ->
        minutes = max(div(retry_after + 59, 60), 1)

        {:noreply,
         put_flash(
           socket,
           :error,
           "You can request one export per hour. Try again in about #{minutes} minute(s)."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start the export. Please try again.")}
    end
  end

  @impl true
  def handle_event("confirm_delete_input", %{"email" => email}, socket) do
    {:noreply, assign(socket, :delete_confirmation, email)}
  end

  # Typing the account's own email is the confirmation. It is not a security
  # control — the session already proves who this is — it is a speed bump, so
  # the irreversible button cannot be hit by reflex.
  @impl true
  def handle_event("delete_account", %{"email" => email}, socket) do
    user = socket.assigns.current_user

    cond do
      email != user.email ->
        {:noreply, put_flash(socket, :error, "Type your email address exactly to confirm.")}

      socket.assigns.deleting ->
        {:noreply, socket}

      true ->
        socket = assign(socket, :deleting, true)

        case Deletion.delete_user(user,
               actor: "self",
               request_ip: socket.assigns[:client_ip]
             ) do
          {:ok, _summary} ->
            # Straight out through the controller so the session is dropped;
            # a LiveView cannot clear the session cookie itself.
            {:noreply, redirect(socket, to: ~p"/auth/logout?deleted=1")}

          {:error, {:stripe, _reason}} ->
            {:noreply,
             socket
             |> assign(:deleting, false)
             |> put_flash(
               :error,
               "Your subscription could not be cancelled, so nothing was deleted. " <>
                 "Please try again, or contact support if it keeps failing."
             )}

          {:error, _reason} ->
            {:noreply,
             socket
             |> assign(:deleting, false)
             |> put_flash(:error, "Account deletion failed. Nothing was deleted.")}
        end
    end
  end

  @impl true
  def handle_info({:export_updated, _user_id}, socket) do
    {:noreply, assign(socket, :export, Exports.latest_export(socket.assigns.current_user.id))}
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

      <%!-- Data export --%>
      <div class="rounded-lg border bg-white p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium">Export your data</h2>
        <p class="mb-2 text-sm text-gray-600">
          Download a single JSON file containing your agents, environments, vaults,
          conversations with their full log output, and your audit trail.
        </p>
        <p class="mb-4 text-sm text-gray-600">
          Environment and vault <strong>secret values are deliberately excluded</strong>
          — only secret names are listed. Secrets were write-only on the way in and
          stay that way on the way out.
        </p>

        <%= if @export do %>
          <div class="mb-4 rounded-md bg-gray-50 p-4 text-sm" id="export-status">
            <%= case export_state(@export) do %>
              <% :pending -> %>
                <span class="text-gray-700">
                  Export requested <%= Calendar.strftime(@export.inserted_at, "%Y-%m-%d %H:%M UTC") %>
                  — generating&hellip; The download will appear here when it is ready.
                </span>
              <% :ready -> %>
                <div class="flex items-center justify-between gap-4">
                  <span class="text-gray-700">
                    Export ready (<%= format_bytes(@export.byte_size) %>) — link expires
                    <%= Calendar.strftime(@export.expires_at, "%Y-%m-%d %H:%M UTC") %>.
                  </span>
                  <a
                    href={~p"/account/exports/#{@export.id}/download"}
                    class="shrink-0 rounded-md bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-700"
                  >
                    Download
                  </a>
                </div>
              <% :expired -> %>
                <span class="text-gray-500">
                  Your last export has expired. Request a new one to download your data.
                </span>
              <% :failed -> %>
                <span class="text-red-700">
                  The last export failed. Please request a new one; contact support if it
                  keeps failing.
                </span>
            <% end %>
          </div>
        <% end %>

        <button
          phx-click="request_export"
          class="rounded-md border border-gray-300 bg-white px-4 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50"
        >
          Request export
        </button>
        <p class="mt-2 text-xs text-gray-400">
          One export per hour. Downloads expire after <%= Exports.ttl_hours() %> hours.
        </p>
      </div>

      <%!-- Danger zone --%>
      <div class="rounded-lg border border-red-200 bg-white p-6 shadow-sm">
        <h2 class="mb-1 text-lg font-medium text-red-700">Delete account</h2>
        <p class="mb-4 text-sm text-gray-600">
          Cancels your subscription, destroys every running sandbox, and permanently
          deletes your agents, environments, vaults, conversations and stored secrets.
          Secrets are encrypted with a key held only for your account; deleting the
          account destroys that key, so they cannot be recovered afterwards by anyone.
          <strong>This cannot be undone.</strong>
        </p>

        <form phx-submit="delete_account" class="space-y-3">
          <label class="block text-sm text-gray-700">
            Type <span class="font-mono font-semibold"><%= @current_user.email %></span> to confirm
            <input
              type="text"
              name="email"
              autocomplete="off"
              value={@delete_confirmation}
              phx-change="confirm_delete_input"
              class="mt-1 block w-full rounded border-gray-300 text-sm shadow-sm"
            />
          </label>

          <button
            type="submit"
            disabled={@delete_confirmation != @current_user.email or @deleting}
            class="rounded bg-red-600 px-4 py-2 text-sm font-medium text-white disabled:cursor-not-allowed disabled:bg-gray-300"
          >
            <%= if @deleting, do: "Deleting…", else: "Delete my account" %>
          </button>
        </form>
      </div>
    </div>
    """
  end

  # ─── Private helpers ───────────────────────────────────────────────────────────

  defp export_state(%{status: "pending"}), do: :pending
  defp export_state(%{status: "failed"}), do: :failed

  defp export_state(%{status: "completed"} = export) do
    if Exports.expired?(export), do: :expired, else: :ready
  end

  defp format_bytes(nil), do: "unknown size"
  defp format_bytes(n) when n < 1024, do: "#{n} B"
  defp format_bytes(n) when n < 1024 * 1024, do: "#{Float.round(n / 1024, 1)} KB"
  defp format_bytes(n), do: "#{Float.round(n / (1024 * 1024), 1)} MB"

  defp current_month_range do
    now = DateTime.utc_now()
    period_start = %DateTime{now | day: 1, hour: 0, minute: 0, second: 0, microsecond: {0, 0}}
    last_day = :calendar.last_day_of_the_month(now.year, now.month)

    period_end = %DateTime{
      now
      | day: last_day,
        hour: 23,
        minute: 59,
        second: 59,
        microsecond: {0, 0}
    }

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

      # Never fall back to `customer_email`. That makes Stripe mint its own
      # Customer whose id we never learn, so the subscription webhook matches no
      # user: the card is charged and the account is never activated. Creating
      # the Customer first means the id is always ours.
      with {:ok, user} <- Billing.ensure_stripe_customer(user) do
        params = %{
          mode: :subscription,
          line_items: [%{price: price_id, quantity: 1}],
          success_url: return_url <> "?checkout=success",
          cancel_url: return_url,
          customer: user.stripe_customer_id,
          # Second route back to the user if the customer link is ever lost —
          # checkout.session.completed carries this through.
          client_reference_id: user.id,
          # Show "Add promotion code" link on the Checkout page. Promotion codes
          # are user-facing redeemable strings tied to coupons created in the
          # Stripe dashboard. Without this flag, the field is hidden by default.
          allow_promotion_codes: true
        }

        case Stripe.Checkout.Session.create(params) do
          {:ok, session} -> {:ok, session.url}
          error -> error
        end
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
