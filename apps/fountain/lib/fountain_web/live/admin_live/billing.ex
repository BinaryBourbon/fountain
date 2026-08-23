defmodule FountainWeb.AdminLive.Billing do
  @moduledoc """
  `/admin/billing` — the health of the Stripe integration.

  Distinct from `/admin/finance`, which is the money. This page answers "is
  subscription state telling the truth": how many accounts sit on each status,
  how many trials are about to end, and which webhook deliveries have failed
  and so left the database behind Stripe. The remedy for a failure shown here
  is the per-account `resync` on `/admin/users`.

  Read-only. Every status chip links into the user list filtered to it, which
  is where the levers are.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Billing
  alias FountainWeb.AdminLive.Users

  @impl true
  def mount(_params, _session, socket) do
    enabled = Billing.enabled?()
    if connected?(socket) and enabled, do: Process.send_after(self(), :refresh, 30_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Billing")
     |> assign(:billing_enabled, enabled)
     |> assign_overview()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 30_000)
    {:noreply, assign_overview(socket)}
  end

  # overview_admin/0 runs real queries (MRR, status counts, webhook events);
  # on a billing-disabled instance nothing renders them, so don't run them.
  defp assign_overview(socket) do
    if socket.assigns.billing_enabled do
      assign(socket, :overview, Billing.overview_admin())
    else
      assign(socket, :overview, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Billing" current={:billing} billing_enabled={@billing_enabled}>
        <:subtitle>
          Subscription state and webhook health. Refreshes every 30s.
        </:subtitle>
      </.admin_header>

      <div :if={not @billing_enabled} class="text-sm text-zinc-500">
        Billing is disabled on this instance.
      </div>

      <div :if={@billing_enabled} class="space-y-6">
        <section class="space-y-3">
          <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
            <.link
              navigate={~p"/admin/finance"}
              class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
            >
              <div class="text-xs text-zinc-500">MRR</div>
              <div class="text-2xl font-semibold tabular-nums">
                {format_mrr(@overview.mrr_cents)}
              </div>
              <div class="text-xs text-zinc-500" title={mrr_split(@overview.mrr_by_plan)}>
                active subscriptions, per plan · finance ↗
              </div>
            </.link>
            <.link
              navigate={Users.users_path(%{status: "trialing", sort: "trial_end", dir: "asc"})}
              class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
            >
              <div class="text-xs text-zinc-500">Trials ending in 7 days</div>
              <div class="text-2xl font-semibold tabular-nums">
                {@overview.trials_ending_7d}
              </div>
              <div class="text-xs text-zinc-500">soonest first ↗</div>
            </.link>
            <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
              <div class="text-xs text-zinc-500">Conversions this month</div>
              <div class="text-2xl font-semibold tabular-nums">
                {@overview.conversions_this_month}
              </div>
              <div class="text-xs text-zinc-500">completed checkouts</div>
            </div>
          </div>
          <div class="flex flex-wrap gap-2">
            <.link
              :for={status <- ~w(trialing active past_due canceled comped)}
              navigate={Users.users_path(%{status: status})}
              class={[
                "inline-flex items-center gap-1.5 rounded px-2 py-1 text-xs font-medium border hover:opacity-75",
                subscription_status_color(status)
              ]}
            >
              {status}
              <span class="tabular-nums">{Map.get(@overview.status_counts, status, 0)}</span>
            </.link>
          </div>
        </section>

        <section class="space-y-3">
          <h2 class="text-lg font-medium">Webhooks</h2>
          <div
            :if={@overview.failed_events != []}
            class="bg-red-50 border border-red-200 rounded px-4 py-3 text-sm space-y-2"
          >
            <div class="font-medium text-red-900">
              {length(@overview.failed_events)} webhook {if length(@overview.failed_events) == 1,
                do: "event is",
                else: "events are"} failing — subscription state may lag Stripe. Repair one account
              with <span class="font-mono">resync</span>
              on <.link navigate={~p"/admin/users"} class="underline">Users</.link>.
            </div>
            <table class="w-full text-sm bg-white rounded border border-red-100 font-mono">
              <tbody>
                <tr :for={f <- @overview.failed_events} class="border-b border-red-50 last:border-0">
                  <td class="px-3 py-1.5 text-xs text-zinc-500 whitespace-nowrap">
                    {format_ts(f.last_failed_at)}
                  </td>
                  <td class="px-3 py-1.5 text-xs">{f.event_type}</td>
                  <td class="px-3 py-1.5 text-xs text-zinc-400">{f.event_id}</td>
                  <td class="px-3 py-1.5 text-xs text-red-700" title={f.error}>
                    ×{f.failure_count} · {String.slice(f.error, 0, 80)}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <div :if={@overview.failed_events == []} class="text-xs text-zinc-400">
            No unresolved webhook failures.
          </div>
          <details class="text-sm">
            <summary class="cursor-pointer text-zinc-500 hover:text-zinc-900">
              Recent webhook events ({length(@overview.recent_events)})
            </summary>
            <table class="w-full mt-2 text-sm bg-white rounded shadow border border-zinc-200 font-mono">
              <tbody>
                <tr :for={e <- @overview.recent_events} class="border-b border-zinc-100 last:border-0">
                  <td class="px-4 py-1.5 text-xs text-zinc-500">{format_ts(e.inserted_at)}</td>
                  <td class="px-4 py-1.5 text-xs">{e.type}</td>
                  <td class="px-4 py-1.5 text-xs text-zinc-400">{e.id}</td>
                </tr>
              </tbody>
            </table>
          </details>
        </section>
      </div>
    </div>
    """
  end

  defp format_mrr(nil), do: "—"

  defp format_mrr(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(to_string(remainder), 2, "0")}/mo"
  end

  # Every active plan behind the MRR tile, for its tooltip.
  defp mrr_split([]), do: nil

  defp mrr_split(by_plan) do
    Enum.map_join(by_plan, " · ", fn line -> "#{line.plan.name} ×#{line.accounts}" end)
  end
end
