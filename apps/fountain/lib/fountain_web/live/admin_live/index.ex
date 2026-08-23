defmodule FountainWeb.AdminLive.Index do
  @moduledoc """
  `/admin` — the funnel, and one tile per thing that could be wrong.

  This page used to be the whole admin panel: six stacked sections, and a
  `mount` plus a ten-second refresh that re-ran every query behind all six
  regardless of which one an operator had scrolled to. The sections are now
  `/admin/users`, `/admin/sandboxes`, `/admin/billing` and `/admin/activity`,
  and what is left here is the glance: is anything on fire, and where do I go.

  Every tile is a link. A number on this page is never the place to act on
  that number — the levers live on the page the tile points at, next to their
  confirmations.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.{Billing, Conversations}
  alias Fountain.Billing.SandboxUsage
  alias FountainWeb.AdminLive.Users

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:billing_enabled, Billing.enabled?())
     |> assign_overview()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)
    {:noreply, assign_overview(socket)}
  end

  defp assign_overview(socket) do
    socket
    |> assign(:funnel, Fountain.Funnel.summary_admin())
    |> assign(:provider_spend, Billing.provider_spend())
    |> assign(:sandbox_count, Conversations._unsafe_count_sandboxes_admin())
    |> assign_billing_overview()
  end

  # overview_admin/0 runs real queries (MRR, status counts, webhook events);
  # on a billing-disabled instance nothing renders them, so don't run them.
  defp assign_billing_overview(socket) do
    if socket.assigns.billing_enabled do
      assign(socket, :billing_overview, Billing.overview_admin())
    else
      assign(socket, :billing_overview, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Admin" current={:overview} billing_enabled={@billing_enabled}>
        <:subtitle>System overview. Refreshes every 10s.</:subtitle>
      </.admin_header>

      <%!-- The one genuinely bad state that has no tile of its own, because a
            count is not the point: which webhooks, and how long they have
            been failing, is on the billing page. --%>
      <.link
        :if={@billing_enabled and @billing_overview.failed_events != []}
        navigate={~p"/admin/billing"}
        class="block bg-red-50 border border-red-200 rounded px-4 py-3 text-sm text-red-900 hover:border-red-400"
      >
        <span class="font-medium">
          {length(@billing_overview.failed_events)} webhook {if length(
                                                                  @billing_overview.failed_events
                                                                ) == 1,
                                                                do: "event is",
                                                                else: "events are"} failing
        </span>
        — subscription state may lag Stripe. See Billing ↗
      </.link>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Funnel</h2>
        <div class="grid grid-cols-2 sm:grid-cols-5 gap-3">
          <div
            :for={stage <- @funnel.stages}
            :if={stage.key != :subscribed or @billing_enabled}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3"
          >
            <div class="text-xs text-zinc-500">{stage_label(stage.key)}</div>
            <div class="text-2xl font-semibold tabular-nums">{stage.count}</div>
            <div class="text-xs text-zinc-500 space-x-2">
              <span :if={stage.conversion}>{format_pct(stage.conversion)} of prev</span>
              <span :if={stage.median_hours}>· median {format_hours(stage.median_hours)}</span>
            </div>
          </div>
        </div>
        <div
          :if={@funnel.stalled.count > 0}
          class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-sm text-amber-900 space-y-1"
        >
          <div class="font-medium">
            {@funnel.stalled.count} verified {if @funnel.stalled.count == 1,
              do: "user has",
              else: "users have"} never started a conversation
          </div>
          <div class="text-xs">
            onboarding:
            <span :for={{state, n} <- Enum.sort(@funnel.stalled.by_onboarding_state)} class="mr-2">
              {state} ×{n}
            </span>
          </div>
          <div class="text-xs">
            built an agent: {@funnel.stalled.built_agent} · created an environment: {@funnel.stalled.built_environment} · built nothing: {@funnel.stalled.built_nothing}
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">At a glance</h2>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <.link
            :if={@billing_enabled}
            navigate={~p"/admin/finance"}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">MRR</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_mrr(@billing_overview.mrr_cents)}
            </div>
            <div class="text-xs text-zinc-500">active subscriptions · finance ↗</div>
          </.link>

          <.link
            :if={@billing_enabled}
            navigate={Users.users_path(%{status: "trialing", sort: "trial_end", dir: "asc"})}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">Trials ending in 7 days</div>
            <div class="text-2xl font-semibold tabular-nums">
              {@billing_overview.trials_ending_7d}
            </div>
            <div class="text-xs text-zinc-500">soonest first ↗</div>
          </.link>

          <.link
            navigate={~p"/admin/sandboxes"}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">Active sandboxes</div>
            <div class="text-2xl font-semibold tabular-nums">{@sandbox_count}</div>
            <div class="text-xs text-zinc-500">running now ↗</div>
          </.link>

          <%!-- Hours, not money: minutes on different providers cost
                different amounts, and only /admin/finance has the rate card
                that turns one into the other. --%>
          <.link
            navigate={~p"/admin/sandboxes"}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">Billable sandbox time</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(@provider_spend.platform_seconds))}
            </div>
            <div class={[
              "text-xs tabular-nums",
              if(idle_share(platform_totals(@provider_spend)) >= 0.5,
                do: "text-amber-600 font-medium",
                else: "text-zinc-500"
              )
            ]}>
              {format_hours(SandboxUsage.hours(@provider_spend.platform_idle_seconds))} idle ↗
            </div>
          </.link>
        </div>
      </section>
    </div>
    """
  end

  # `idle_share/1` reads the same shape a per-provider row has, so the
  # platform totals are put into that shape rather than the ratio recomputed.
  defp platform_totals(spend) do
    %{active_seconds: spend.platform_seconds, idle_seconds: spend.platform_idle_seconds}
  end

  defp stage_label(:registered), do: "Registered"
  defp stage_label(:verified), do: "Verified"
  defp stage_label(:onboarded), do: "Onboarded"
  defp stage_label(:activated), do: "Activated"
  defp stage_label(:subscribed), do: "Subscribed"

  defp format_pct(fraction), do: "#{round(fraction * 100)}%"

  defp format_mrr(nil), do: "—"

  defp format_mrr(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100)
    "$#{dollars}.#{String.pad_leading(to_string(remainder), 2, "0")}/mo"
  end
end
