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

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:credits_enabled, Fountain.Credits.enabled?())
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

  # overview_admin/0 runs real queries (funded accounts, deferred credit,
  # webhook events);
  # on a billing-disabled instance nothing renders them, so don't run them.
  defp assign_billing_overview(socket) do
    if socket.assigns.credits_enabled do
      assign(socket, :billing_overview, Billing.overview_admin())
    else
      assign(socket, :billing_overview, nil)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Admin" current={:overview} credits_enabled={@credits_enabled}>
        <:subtitle>System overview. Refreshes every 10s.</:subtitle>
      </.admin_header>

      <%!-- The one genuinely bad state that has no tile of its own, because a
            count is not the point: which webhooks, and how long they have
            been failing, is on the billing page. --%>
      <.link
        :if={@credits_enabled and @billing_overview.failed_events != []}
        navigate={~p"/admin/finance"}
        class="block bg-red-50 border border-red-200 rounded px-4 py-3 text-sm text-red-900 hover:border-red-400"
      >
        <span class="font-medium">
          {length(@billing_overview.failed_events)} webhook {if length(
                                                                  @billing_overview.failed_events
                                                                ) == 1,
                                                                do: "event is",
                                                                else: "events are"} failing
        </span>
        — a purchase or a clawback may not have reached the ledger. See Billing ↗
      </.link>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Funnel</h2>
        <div class="grid grid-cols-2 sm:grid-cols-5 gap-3">
          <div
            :for={stage <- @funnel.stages}
            :if={stage.key != :funded or @credits_enabled}
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
        <%!-- The number ADR 0038 judges onboarding on. Verification to the
              first reply, not to the first conversation: an attempt that
              never answered is not an activation. --%>
        <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3 text-sm space-y-1">
          <div class="font-medium">Time to first reply</div>
          <div :if={@funnel.time_to_first_reply.count > 0} class="text-zinc-700 space-x-2">
            <span>
              median
              <span class="font-semibold tabular-nums">
                {format_hours(@funnel.time_to_first_reply.median_hours)}
              </span>
            </span>
            <span>
              · p90
              <span class="font-semibold tabular-nums">
                {format_hours(@funnel.time_to_first_reply.p90_hours)}
              </span>
            </span>
            <span class="text-zinc-500">
              · over {@funnel.time_to_first_reply.count} activated {if @funnel.time_to_first_reply.count ==
                                                                         1,
                                                                       do: "account",
                                                                       else: "accounts"}
            </span>
          </div>
          <div :if={@funnel.time_to_first_reply.count == 0} class="text-zinc-500">
            No account has had a reply yet.
          </div>
          <div :if={@funnel.time_to_first_reply.within_day_of > 0} class="text-xs text-zinc-500">
            within a day of verifying: {@funnel.time_to_first_reply.within_day} of {@funnel.time_to_first_reply.within_day_of}
            <span :if={@funnel.time_to_first_reply.within_day_share}>
              ({format_pct(@funnel.time_to_first_reply.within_day_share)})
            </span>
            — accounts verified less than a day ago are counted in neither.
          </div>
        </div>
        <div
          :if={@funnel.stalled.count > 0}
          class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-sm text-amber-900 space-y-1"
        >
          <div class="font-medium">
            {@funnel.stalled.count} verified {if @funnel.stalled.count == 1,
              do: "user has",
              else: "users have"} never had a reply
          </div>
          <div class="text-xs">
            started a conversation and got nothing back: {@funnel.stalled.started}
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
            :if={@credits_enabled}
            navigate={~p"/admin/finance"}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">Deferred credit</div>
            <div class="text-2xl font-semibold tabular-nums">
              {Fountain.Credits.format_cents(@billing_overview.deferred_cents || 0)}
            </div>
            <div class="text-xs text-zinc-500">
              held by {@billing_overview.funded} funded accounts · finance ↗
            </div>
          </.link>

          <.link
            :if={@credits_enabled}
            navigate={~p"/admin/finance"}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">Packs bought this month</div>
            <div class="text-2xl font-semibold tabular-nums">
              {@billing_overview.purchases_this_month}
            </div>
            <div class="text-xs text-zinc-500">{@billing_overview.comped} comped accounts ↗</div>
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
  defp stage_label(:funded), do: "Funded"

  defp format_pct(fraction), do: "#{round(fraction * 100)}%"
end
