defmodule FountainWeb.AdminLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers

  alias Fountain.{Accounts, Billing, Conversations, Quotas}
  alias Fountain.Accounts.Deletion
  alias Fountain.Billing.SandboxUsage

  @usage_window_days 30
  @per_page 25
  @statuses ~w(trialing active past_due canceled comped)
  @sorts ~w(email joined trial_end last_activity)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> FountainWeb.Audited.put_client_ip()
     |> assign(:page_title, "Admin")
     |> assign(:billing_enabled, Billing.enabled?())
     |> assign(:funnel, Fountain.Funnel.summary_admin())
     |> assign_billing_overview()
     |> assign(:provider_spend, Billing.provider_spend())
     |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
     |> assign(:admin_events, Fountain.Audit._unsafe_list_recent_admin(25))}
  end

  # Filter/sort/page state lives in the URL, so the 10s refresh, admin
  # actions, and browser reloads all preserve position.
  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> assign(:filters, parse_filters(params))
     |> assign_users()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)

    {:noreply,
     socket
     |> assign_users()
     |> assign(:funnel, Fountain.Funnel.summary_admin())
     |> assign_billing_overview()
     |> assign(:provider_spend, Billing.provider_spend())
     |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
     |> assign(:admin_events, Fountain.Audit._unsafe_list_recent_admin(25))}
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
  def handle_event("filter", params, socket) do
    filters = %{
      socket.assigns.filters
      | search: params["q"] || "",
        status: if(params["status"] in @statuses, do: params["status"]),
        role: if(params["role"] in ~w(admin user), do: params["role"]),
        verified: parse_verified(params["verified"]),
        page: 1
    }

    {:noreply, push_patch(socket, to: admin_path(filters))}
  end

  @impl true
  def handle_event("toggle_admin", %{"id" => id}, socket) do
    with_target_user(socket, id, fn user -> do_toggle_admin(socket, user) end)
  end

  # The concurrency cap is the only lever for a noisy or abusive tenant
  # (ADR 0005). Without this it is adjustable only with direct database access,
  # which makes it useless in an incident.
  @impl true
  def handle_event("set_sandbox_limit", %{"user_id" => id, "limit" => raw}, socket) do
    with {limit, ""} <- Integer.parse(String.trim(raw)),
         %Accounts.User{} = user <- Accounts.get_user(id),
         {:ok, _} <- Accounts.update_sandbox_limit(user, limit, actor: "admin") do
      Fountain.Audit.record_admin(%{
        actor_user_id: socket.assigns.current_user.id,
        target_user_id: user.id,
        event_type: "admin.sandbox_limit.changed",
        metadata: %{
          "email" => user.email,
          "from" => user.max_concurrent_sandboxes,
          "to" => limit
        }
      })

      {:noreply, socket |> assign_users() |> put_flash(:info, "Sandbox limit updated")}
    else
      nil ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:error, "User not found — the account may have been deleted")}

      _ ->
        {:noreply, put_flash(socket, :error, "Limit must be a whole number of 0 or more")}
    end
  end

  # The buttons are hidden when billing is disabled, but events can still be
  # sent by hand (#399's lesson) — and all of these actions talk to Stripe.
  @impl true
  def handle_event(event, _params, %{assigns: %{billing_enabled: false}} = socket)
      when event in ~w(extend_trial toggle_comp resync_stripe) do
    {:noreply, put_flash(socket, :error, "Billing is disabled on this instance")}
  end

  @impl true
  def handle_event("extend_trial", %{"user_id" => id, "days" => raw}, socket) do
    with {days, ""} when days > 0 <- Integer.parse(String.trim(raw)),
         %Accounts.User{} = user <- Accounts.get_user(id),
         {:ok, updated} <- Billing.extend_trial(user, days) do
      Fountain.Audit.record_admin(%{
        actor_user_id: socket.assigns.current_user.id,
        target_user_id: user.id,
        event_type: "admin.trial.extended",
        metadata: %{
          "email" => user.email,
          "from" => user.trial_ends_at && DateTime.to_iso8601(user.trial_ends_at),
          "to" => DateTime.to_iso8601(updated.trial_ends_at)
        }
      })

      {:noreply,
       socket
       |> assign_users()
       |> put_flash(:info, "Trial extended to #{format_date(updated.trial_ends_at)}")}
    else
      {:error, :active_subscription} ->
        {:noreply, put_flash(socket, :error, "Account has an active paid subscription")}

      {:error, :comped} ->
        {:noreply, put_flash(socket, :error, "Account is comped — nothing to extend")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not extend trial — Stripe refused")}

      nil ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:error, "User not found — the account may have been deleted")}

      _ ->
        {:noreply, put_flash(socket, :error, "Days must be a whole number of 1 or more")}
    end
  end

  @impl true
  def handle_event("toggle_comp", %{"id" => id}, socket) do
    with_target_user(socket, id, fn user -> do_toggle_comp(socket, user) end)
  end

  # The in-app remedy for webhook drift (#502): re-read the subscription of
  # record from Stripe and adopt what it says, without a Stripe dashboard
  # round-trip.
  @impl true
  def handle_event("resync_stripe", %{"id" => id}, socket) do
    with_target_user(socket, id, fn user -> do_resync_stripe(socket, user) end)
  end

  @impl true
  def handle_event("reap_sandbox", %{"id" => id}, socket) do
    case Conversations._unsafe_reap_sandbox(id) do
      {:ok, outcome} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: nil,
          event_type: "admin.sandbox.reaped",
          metadata: %{"sandbox_id" => id, "outcome" => to_string(outcome)}
        })

        msg =
          case outcome do
            :terminated -> "Sandbox and its live conversations terminated"
            :released -> "Sandbox released — conversations stay resumable"
            :already_terminal -> "Sandbox was already terminated"
          end

        {:noreply,
         socket
         |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
         |> assign_users()
         |> put_flash(:info, msg)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Sandbox not found")}
    end
  end

  # The reversible abuse lever between comp and delete (#287): sessions die,
  # API keys refuse, sandboxes are reaped — and it all comes back with one
  # click. Billing is deliberately untouched; see Accounts.suspend_user/1.
  @impl true
  def handle_event("toggle_suspend", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    if id == admin.id do
      {:noreply, put_flash(socket, :error, "You cannot suspend your own account")}
    else
      with_target_user(socket, id, fn user -> do_toggle_suspend(socket, admin, user) end)
    end
  end

  # The support path for a deletion request that cannot go through the account
  # page — a locked-out user, or one who asked by email. Same teardown as
  # self-serve; only the actor recorded differs.
  @impl true
  def handle_event("delete_user", %{"id" => id}, socket) do
    admin = socket.assigns.current_user

    if id == admin.id do
      # The UI hides the button, but an event can still be sent by hand. An
      # admin deleting themselves mid-session is a support problem, not a
      # feature.
      {:noreply, put_flash(socket, :error, "Use your own account page to delete your account")}
    else
      with_target_user(socket, id, fn user -> do_delete_user(socket, admin, user) end)
    end
  end

  # Non-bang lookup for every admin action targeting a user row (#401): the
  # table is loaded at mount, so acting on a user deleted since (another
  # admin tab, self-deletion) made get_user! raise and kill the LiveView.
  defp with_target_user(socket, id, fun) do
    case Accounts.get_user(id) do
      nil ->
        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:error, "User not found — the account may have been deleted")}

      user ->
        fun.(user)
    end
  end

  defp do_toggle_admin(socket, user) do
    new_role = if user.role == "admin", do: "user", else: "admin"

    case Accounts.update_user_role(user, new_role, actor: "admin") do
      {:ok, _} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: user.id,
          event_type:
            if(new_role == "admin", do: "admin.role.granted", else: "admin.role.revoked"),
          metadata: %{"email" => user.email, "from" => user.role, "to" => new_role}
        })

        {:noreply, socket |> assign_users() |> put_flash(:info, "Role updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update role")}
    end
  end

  defp do_toggle_comp(socket, user) do
    result =
      if user.subscription_status == "comped",
        do: {Billing.revoke_comp(user), "admin.comp.revoked"},
        else: {Billing.comp_account(user), "admin.comp.granted"}

    case result do
      {{:ok, updated}, event_type} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: user.id,
          event_type: event_type,
          metadata: %{
            "email" => user.email,
            "from" => user.subscription_status,
            "to" => updated.subscription_status
          }
        })

        {:noreply,
         socket |> assign_users() |> put_flash(:info, "Now #{updated.subscription_status}")}

      {{:error, _}, _} ->
        {:noreply,
         put_flash(socket, :error, "Could not change comp — Stripe cancellation failed")}
    end
  end

  defp do_resync_stripe(socket, user) do
    case Billing.resync_from_stripe(user) do
      {:ok, %Accounts.User{} = updated} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: user.id,
          event_type: "admin.stripe.resynced",
          metadata: %{
            "email" => user.email,
            "from" => user.subscription_status,
            "to" => updated.subscription_status
          }
        })

        {:noreply,
         socket
         |> assign_users()
         |> put_flash(:info, "Resynced from Stripe — status #{updated.subscription_status}")}

      {:ok, :sync_enqueued} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: socket.assigns.current_user.id,
          target_user_id: user.id,
          event_type: "admin.stripe.resynced",
          metadata: %{"email" => user.email, "outcome" => "customer_sync_enqueued"}
        })

        {:noreply,
         put_flash(
           socket,
           :info,
           "No subscription on record — customer sync enqueued, check back shortly"
         )}

      {:error, :comped} ->
        {:noreply,
         put_flash(socket, :error, "Account is comped — Stripe does not drive its status")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not resync — Stripe refused the read")}
    end
  end

  defp do_toggle_suspend(socket, admin, user) do
    if Accounts.suspended?(user) do
      case Accounts.unsuspend_user(user, actor: "admin") do
        {:ok, _} ->
          Fountain.Audit.record_admin(%{
            actor_user_id: admin.id,
            target_user_id: user.id,
            event_type: "admin.account.unsuspended",
            metadata: %{"email" => user.email}
          })

          {:noreply, socket |> assign_users() |> put_flash(:info, "Suspension lifted")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not lift the suspension")}
      end
    else
      case Accounts.suspend_user(user, actor: "admin") do
        {:ok, _, reaped} ->
          Fountain.Audit.record_admin(%{
            actor_user_id: admin.id,
            target_user_id: user.id,
            event_type: "admin.account.suspended",
            metadata: %{"email" => user.email, "sandboxes_reaped" => reaped}
          })

          {:noreply,
           socket
           |> assign_users()
           |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
           |> put_flash(:info, "Suspended — #{reaped} sandbox(es) reaped")}

        {:error, _} ->
          {:noreply, put_flash(socket, :error, "Could not suspend the account")}
      end
    end
  end

  defp do_delete_user(socket, admin, user) do
    case Deletion.delete_user(user,
           actor: "admin:#{admin.id}",
           request_ip: socket.assigns[:client_ip]
         ) do
      {:ok, _summary} ->
        Fountain.Audit.record_admin(%{
          actor_user_id: admin.id,
          target_user_id: user.id,
          event_type: "admin.account.deleted",
          metadata: %{"email" => user.email}
        })

        {:noreply,
         socket
         |> assign_users()
         |> assign(:sandboxes, Conversations._unsafe_list_sandboxes_admin())
         |> put_flash(:info, "Deleted #{user.email}")}

      {:error, {:stripe, _}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not cancel #{user.email}'s subscription — nothing was deleted"
         )}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Deletion failed — nothing was deleted")}
    end
  end

  defp assign_users(socket) do
    f = socket.assigns.filters
    now = DateTime.utc_now()

    # Upper bound one second ahead: the column is second-precision, so a bound
    # of `now` loses its sub-second part in the cast and excludes events
    # recorded within the current second.
    usage =
      Billing.usage_summaries(
        DateTime.add(now, -@usage_window_days, :day),
        DateTime.add(now, 1, :second)
      )

    no_usage = %{
      conversations: 0,
      turns: 0,
      sandbox_minutes: 0.0,
      sandbox_minutes_by_provider: %{}
    }

    sandbox_counts = Quotas.active_sandbox_counts()

    %{users: users, total: total} =
      Accounts.list_users_admin(
        search: f.search,
        status: f.status,
        role: f.role,
        verified: f.verified,
        sort: f.sort,
        dir: f.dir,
        page: f.page,
        per_page: @per_page
      )

    users =
      Enum.map(users, fn u ->
        u
        |> Map.put(:active_sandboxes, Map.get(sandbox_counts, u.id, 0))
        |> Map.put(:usage, Map.get(usage, u.id, no_usage))
      end)

    socket
    |> assign(:users, users)
    |> assign(:total_users, total)
  end

  defp parse_filters(params) do
    %{
      search: params["q"] || "",
      status: if(params["status"] in @statuses, do: params["status"]),
      role: if(params["role"] in ~w(admin user), do: params["role"]),
      verified: parse_verified(params["verified"]),
      sort: if(params["sort"] in @sorts, do: params["sort"], else: "joined"),
      dir: if(params["dir"] in ~w(asc desc), do: params["dir"], else: "desc"),
      page: parse_page(params["page"])
    }
  end

  defp parse_verified("yes"), do: true
  defp parse_verified("no"), do: false
  defp parse_verified(_), do: nil

  defp parse_page(raw) do
    case is_binary(raw) && Integer.parse(raw) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end

  defp admin_path(f) do
    params =
      [
        q: if(f.search != "", do: f.search),
        status: f.status,
        role: f.role,
        verified:
          case f.verified do
            true -> "yes"
            false -> "no"
            nil -> nil
          end,
        sort: if(f.sort != "joined", do: f.sort),
        dir: if(f.dir != "desc", do: f.dir),
        page: if(f.page > 1, do: f.page)
      ]
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)

    ~p"/admin?#{params}"
  end

  defp sort_toggle(f, col) do
    cond do
      f.sort == col -> %{f | dir: flip(f.dir), page: 1}
      col == "email" -> %{f | sort: col, dir: "asc", page: 1}
      true -> %{f | sort: col, dir: "desc", page: 1}
    end
  end

  defp flip("asc"), do: "desc"
  defp flip(_), do: "asc"

  defp page_count(total), do: max(div(total + @per_page - 1, @per_page), 1)

  attr :label, :string, required: true
  attr :col, :string, required: true
  attr :filters, :map, required: true

  defp sort_header(assigns) do
    ~H"""
    <.link patch={admin_path(sort_toggle(@filters, @col))} class="hover:text-zinc-900">
      {@label}<span :if={@filters.sort == @col}> {if @filters.dir == "asc", do: "▲", else: "▼"}</span>
    </.link>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-8">
      <div>
        <h1 class="text-2xl font-semibold">Admin</h1>
        <p class="text-sm text-zinc-500 mt-1">System overview. Refreshes every 10s.</p>
      </div>

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

      <%!-- Not gated on @billing_enabled: a self-hosted instance still pays a
            provider bill, and this is the only place that says whose sandboxes
            it is for. --%>
      <section class="space-y-3">
        <h2 class="text-lg font-medium">Sandbox spend by provider</h2>
        <p class="text-xs text-zinc-500">
          Active sandbox time {Calendar.strftime(@provider_spend.period_start, "%b %-d")} – now,
          parked time excluded. Minutes on different providers cost different amounts — hold these
          next to the invoice, they are not money.
        </p>

        <div :if={@provider_spend.by_provider == %{}} class="text-xs text-zinc-400">
          No sandbox time this month.
        </div>

        <div :if={@provider_spend.by_provider != %{}} class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <div
            :for={{provider, totals} <- Enum.sort(@provider_spend.by_provider)}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3"
          >
            <div class="text-xs text-zinc-500">{provider}</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_hours(SandboxUsage.hours(totals.active_seconds))}
            </div>
            <div class="text-xs text-zinc-500 tabular-nums">
              {totals.sandboxes} sandboxes · {totals.users} {if totals.users == 1,
                do: "tenant",
                else: "tenants"}
            </div>
            <div
              class="text-xs tabular-nums"
              title="No turn in flight. A shorter idle timeout removes this."
            >
              <span class={
                if idle_share(totals) >= 0.5, do: "text-amber-600 font-medium", else: "text-zinc-500"
              }>
                {format_hours(SandboxUsage.hours(totals.idle_seconds))} idle
              </span>
              <span class="text-zinc-400">({round(idle_share(totals) * 100)}%)</span>
            </div>
            <div :if={not SandboxUsage.platform_cost?(provider)} class="text-xs text-zinc-400">
              tenant hardware, not our bill
            </div>
          </div>
        </div>

        <div class="text-xs text-zinc-500 tabular-nums">
          Billable to us: {format_hours(SandboxUsage.hours(@provider_spend.platform_seconds))}
          <span :if={@provider_spend.platform_seconds > 0} class="text-zinc-400">
            · {format_hours(SandboxUsage.hours(@provider_spend.platform_idle_seconds))} of it idle,
            which is what a shorter idle timeout would remove
          </span>
        </div>

        <div
          :if={@provider_spend.top_tenants != []}
          class="bg-white rounded shadow border border-zinc-200"
        >
          <div class="px-4 py-2 text-xs font-medium text-zinc-500 border-b border-zinc-200">
            Who it belongs to
          </div>
          <ul class="divide-y divide-zinc-100">
            <li
              :for={tenant <- @provider_spend.top_tenants}
              class="px-4 py-2 text-xs flex items-center justify-between gap-3"
            >
              <span class="truncate">
                {tenant.email || "(deleted account)"}
                <span class="text-zinc-400">· {tenant.provider}</span>
              </span>
              <span class="tabular-nums whitespace-nowrap text-zinc-500">
                {format_hours(SandboxUsage.hours(tenant.active_seconds))}
                <span class="text-zinc-400">
                  ({round(idle_share(tenant) * 100)}% idle)
                </span>
                · {tenant.sandboxes} sandboxes
              </span>
            </li>
          </ul>
        </div>
      </section>

      <section :if={@billing_enabled} class="space-y-3">
        <h2 class="text-lg font-medium">Billing</h2>
        <div class="grid grid-cols-2 sm:grid-cols-3 gap-3">
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">MRR</div>
            <div class="text-2xl font-semibold tabular-nums">
              {format_mrr(@billing_overview.mrr_cents)}
            </div>
            <div class="text-xs text-zinc-500">
              {if @billing_overview.mrr_cents,
                do: "active × monthly price",
                else: "set STRIPE_PRICE_MONTHLY_CENTS"}
            </div>
          </div>
          <.link
            navigate={~p"/admin?status=trialing&sort=trial_end&dir=asc"}
            class="bg-white rounded shadow border border-zinc-200 px-4 py-3 hover:border-zinc-400"
          >
            <div class="text-xs text-zinc-500">Trials ending in 7 days</div>
            <div class="text-2xl font-semibold tabular-nums">
              {@billing_overview.trials_ending_7d}
            </div>
            <div class="text-xs text-zinc-500">soonest first ↗</div>
          </.link>
          <div class="bg-white rounded shadow border border-zinc-200 px-4 py-3">
            <div class="text-xs text-zinc-500">Conversions this month</div>
            <div class="text-2xl font-semibold tabular-nums">
              {@billing_overview.conversions_this_month}
            </div>
            <div class="text-xs text-zinc-500">completed checkouts</div>
          </div>
        </div>
        <div class="flex flex-wrap gap-2">
          <.link
            :for={status <- ~w(trialing active past_due canceled comped)}
            navigate={~p"/admin?status=#{status}"}
            class={[
              "inline-flex items-center gap-1.5 rounded px-2 py-1 text-xs font-medium border hover:opacity-75",
              subscription_status_color(status)
            ]}
          >
            {status}
            <span class="tabular-nums">{Map.get(@billing_overview.status_counts, status, 0)}</span>
          </.link>
        </div>
        <div
          :if={@billing_overview.failed_events != []}
          class="bg-red-50 border border-red-200 rounded px-4 py-3 text-sm space-y-2"
        >
          <div class="font-medium text-red-900">
            {length(@billing_overview.failed_events)} webhook {if length(
                                                                    @billing_overview.failed_events
                                                                  ) == 1,
                                                                  do: "event is",
                                                                  else: "events are"} failing — subscription state may lag Stripe
          </div>
          <table class="w-full text-sm bg-white rounded border border-red-100 font-mono">
            <tbody>
              <tr
                :for={f <- @billing_overview.failed_events}
                class="border-b border-red-50 last:border-0"
              >
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
        <div :if={@billing_overview.failed_events == []} class="text-xs text-zinc-400">
          No unresolved webhook failures.
        </div>
        <details class="text-sm">
          <summary class="cursor-pointer text-zinc-500 hover:text-zinc-900">
            Recent webhook events ({length(@billing_overview.recent_events)})
          </summary>
          <table class="w-full mt-2 text-sm bg-white rounded shadow border border-zinc-200 font-mono">
            <tbody>
              <tr
                :for={e <- @billing_overview.recent_events}
                class="border-b border-zinc-100 last:border-0"
              >
                <td class="px-4 py-1.5 text-xs text-zinc-500">{format_ts(e.inserted_at)}</td>
                <td class="px-4 py-1.5 text-xs">{e.type}</td>
                <td class="px-4 py-1.5 text-xs text-zinc-400">{e.id}</td>
              </tr>
            </tbody>
          </table>
        </details>
      </section>

      <section class="space-y-3">
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-lg font-medium">Users ({@total_users})</h2>
          <form phx-change="filter" id="user-filters" class="flex flex-wrap items-center gap-2">
            <input
              type="text"
              name="q"
              value={@filters.search}
              placeholder="Search email…"
              phx-debounce="300"
              autocomplete="off"
              class="w-48 rounded border border-zinc-200 px-2 py-1 text-xs"
            />
            <select
              :if={@billing_enabled}
              name="status"
              class="rounded border border-zinc-200 px-1 py-1 text-xs"
            >
              <option value="">any status</option>
              <option
                :for={s <- ~w(trialing active past_due canceled comped)}
                value={s}
                selected={@filters.status == s}
              >
                {s}
              </option>
            </select>
            <select name="role" class="rounded border border-zinc-200 px-1 py-1 text-xs">
              <option value="">any role</option>
              <option value="admin" selected={@filters.role == "admin"}>admin</option>
              <option value="user" selected={@filters.role == "user"}>user</option>
            </select>
            <select name="verified" class="rounded border border-zinc-200 px-1 py-1 text-xs">
              <option value="">any verification</option>
              <option value="yes" selected={@filters.verified == true}>verified</option>
              <option value="no" selected={@filters.verified == false}>unverified</option>
            </select>
          </form>
        </div>
        <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">
                <.sort_header label="Email" col="email" filters={@filters} />
              </th>
              <th class="px-4 py-2">Role</th>
              <th :if={@billing_enabled} class="px-4 py-2">
                <.sort_header label="Billing" col="trial_end" filters={@filters} />
              </th>
              <th class="px-4 py-2" title="Last 30 days: conversations / turns / sandbox minutes">
                Usage 30d
              </th>
              <th class="px-4 py-2">Sandboxes</th>
              <th class="px-4 py-2">Onboarding</th>
              <th class="px-4 py-2">
                <.sort_header label="Last active" col="last_activity" filters={@filters} />
              </th>
              <th class="px-4 py-2">
                <.sort_header label="Joined" col="joined" filters={@filters} />
              </th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :if={@users == []}>
              <td
                colspan={if @billing_enabled, do: "9", else: "8"}
                class="px-4 py-6 text-center text-sm text-zinc-500"
              >
                No users match.
              </td>
            </tr>
            <tr :for={u <- @users} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
              <td class="px-4 py-2 font-mono text-xs">
                <.link navigate={~p"/admin/users/#{u.id}"} class="hover:underline">
                  {u.email}
                </.link>
                <span
                  :if={is_nil(u.email_verified_at)}
                  class="ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border bg-zinc-100 text-zinc-500 border-zinc-200"
                >
                  unverified
                </span>
                <span
                  :if={u.suspended_at}
                  class="ml-1 inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border bg-red-100 text-red-700 border-red-200"
                  title={"since #{format_ts(u.suspended_at)}"}
                >
                  suspended
                </span>
              </td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  if(u.role == "admin",
                    do: "bg-amber-100 text-amber-800 border-amber-200",
                    else: "bg-zinc-100 text-zinc-600 border-zinc-200"
                  )
                ]}>
                  {u.role}
                </span>
              </td>
              <td :if={@billing_enabled} class="px-4 py-2">
                <div class="space-y-1">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                      subscription_status_color(u.subscription_status)
                    ]}>
                      {u.subscription_status}
                    </span>
                    <span
                      :if={u.subscription_status == "trialing" and u.trial_ends_at}
                      class="text-xs text-zinc-500"
                    >
                      ends {format_date(u.trial_ends_at)}
                    </span>
                    <a
                      :if={u.stripe_customer_id not in [nil, ""]}
                      href={"https://dashboard.stripe.com/customers/#{u.stripe_customer_id}"}
                      target="_blank"
                      rel="noopener"
                      class="text-xs text-zinc-400 hover:text-zinc-700 underline"
                    >
                      stripe ↗
                    </a>
                  </div>
                  <div class="flex items-center gap-2">
                    <form
                      :if={u.subscription_status not in ["active", "comped"]}
                      phx-submit="extend_trial"
                      id={"extend-trial-#{u.id}"}
                      class="flex items-center gap-1"
                    >
                      <input type="hidden" name="user_id" value={u.id} />
                      <input
                        type="number"
                        name="days"
                        min="1"
                        value="14"
                        class="w-12 rounded border border-zinc-200 px-1 py-0.5 text-xs"
                      />
                      <button class="text-xs text-zinc-500 hover:text-zinc-900 underline">
                        extend trial
                      </button>
                    </form>
                    <button
                      phx-click="toggle_comp"
                      phx-value-id={u.id}
                      data-confirm={
                        if u.subscription_status == "comped",
                          do: "Revoke #{u.email}'s comp? They become canceled and must subscribe.",
                          else:
                            "Comp #{u.email}? Free access until revoked. Any Stripe subscription is cancelled."
                      }
                      class="text-xs text-zinc-500 hover:text-zinc-900 underline"
                    >
                      {if u.subscription_status == "comped", do: "revoke comp", else: "comp"}
                    </button>
                    <button
                      :if={u.subscription_status != "comped"}
                      phx-click="resync_stripe"
                      phx-value-id={u.id}
                      title="Re-read subscription state from Stripe — repairs webhook drift"
                      class="text-xs text-zinc-500 hover:text-zinc-900 underline"
                    >
                      resync
                    </button>
                  </div>
                </div>
              </td>
              <td
                class="px-4 py-2 text-xs text-zinc-500 tabular-nums whitespace-nowrap"
                title={provider_split(u.usage.sandbox_minutes_by_provider)}
              >
                {u.usage.conversations}c · {u.usage.turns}t · {round(u.usage.sandbox_minutes)}m
              </td>
              <td class="px-4 py-2">
                <form
                  phx-submit="set_sandbox_limit"
                  id={"sandbox-limit-#{u.id}"}
                  class="flex items-center gap-1"
                >
                  <input type="hidden" name="user_id" value={u.id} />
                  <span class={[
                    "text-xs tabular-nums",
                    if(u.active_sandboxes >= u.max_concurrent_sandboxes,
                      do: "text-red-600 font-medium",
                      else: "text-zinc-500"
                    )
                  ]}>
                    {u.active_sandboxes} /
                  </span>
                  <input
                    type="number"
                    name="limit"
                    min="0"
                    value={u.max_concurrent_sandboxes}
                    class="w-14 rounded border border-zinc-200 px-1 py-0.5 text-xs"
                  />
                  <button class="text-xs text-zinc-500 hover:text-zinc-900 underline">set</button>
                </form>
              </td>
              <td class="px-4 py-2 text-zinc-500 text-xs">
                {u.onboarding_state}
                <span :if={u.onboarding_completed_at} class="text-zinc-400">
                  · {format_date(u.onboarding_completed_at)}
                </span>
              </td>
              <td class="px-4 py-2 text-zinc-500 text-xs">
                {if u.last_activity_at, do: format_date(u.last_activity_at), else: "—"}
              </td>
              <td class="px-4 py-2 text-zinc-500 text-xs">{format_date(u.inserted_at)}</td>
              <td class="px-4 py-2 text-right space-x-3">
                <button
                  phx-click="toggle_admin"
                  phx-value-id={u.id}
                  data-confirm={"Toggle admin for #{u.email}?"}
                  class="text-xs text-zinc-600 hover:text-zinc-900 underline"
                >
                  {if u.role == "admin", do: "Remove admin", else: "Make admin"}
                </button>
                <button
                  :if={u.id != @current_user.id}
                  phx-click="toggle_suspend"
                  phx-value-id={u.id}
                  data-confirm={
                    if u.suspended_at,
                      do: "Lift #{u.email}'s suspension? They can log in again immediately.",
                      else:
                        "Suspend #{u.email}? Sessions and API keys stop working and running conversations are terminated. Reversible; billing is not touched."
                  }
                  class="text-xs text-amber-700 hover:text-amber-900 underline"
                >
                  {if u.suspended_at, do: "Unsuspend", else: "Suspend"}
                </button>
                <button
                  :if={u.id != @current_user.id}
                  phx-click="delete_user"
                  phx-value-id={u.id}
                  data-confirm={"Permanently delete #{u.email}? This cancels their subscription, destroys their sandboxes and erases their data. It cannot be undone."}
                  class="text-xs text-red-600 hover:text-red-800 underline"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
        <div
          :if={page_count(@total_users) > 1 or @filters.page > 1}
          class="flex items-center justify-between text-xs text-zinc-500"
        >
          <span>Page {@filters.page} of {page_count(@total_users)}</span>
          <div class="space-x-3">
            <.link
              :if={@filters.page > 1}
              patch={admin_path(%{@filters | page: @filters.page - 1})}
              class="underline"
            >
              ← prev
            </.link>
            <.link
              :if={@filters.page < page_count(@total_users)}
              patch={admin_path(%{@filters | page: @filters.page + 1})}
              class="underline"
            >
              next →
            </.link>
          </div>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Active sandboxes ({length(@sandboxes)})</h2>

        <div :if={@sandboxes == []} class="text-sm text-zinc-500">No active sandboxes.</div>

        <table
          :if={@sandboxes != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200 font-mono"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">ID</th>
              <th class="px-4 py-2">Owner</th>
              <th class="px-4 py-2">Status</th>
              <th class="px-4 py-2">Conversations</th>
              <th class="px-4 py-2">Started</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @sandboxes} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-2 text-xs">{String.slice(s.id, 0, 8)}</td>
              <td class="px-4 py-2 text-xs">
                <.link
                  :if={s.user}
                  navigate={~p"/admin/users/#{s.user.id}"}
                  class="hover:underline"
                >
                  {s.user.email}
                </.link>
                <span :if={is_nil(s.user)} class="text-zinc-400">—</span>
              </td>
              <td class="px-4 py-2">
                <span class={[
                  "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                  sandbox_status_color(s.status)
                ]}>
                  {s.status}
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">
                <span :if={s.conversations == []}>—</span>
                <span :if={s.conversations != []} class="space-x-2">
                  <.link
                    :for={c <- s.conversations}
                    navigate={~p"/admin/conversations/#{c.id}"}
                    class="hover:underline"
                  >
                    {String.slice(c.id, 0, 8)}
                  </.link>
                </span>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_ts(s.inserted_at)}</td>
              <td class="px-4 py-2 text-right">
                <button
                  phx-click="reap_sandbox"
                  phx-value-id={s.id}
                  data-confirm={"Reap sandbox #{String.slice(s.id, 0, 8)}? Live conversations are terminated; idle ones stay resumable on a fresh sandbox."}
                  class="text-xs text-red-600 hover:text-red-800 underline"
                >
                  Reap
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
      <section class="space-y-3">
        <h2 class="text-lg font-medium">Recent admin actions</h2>
        <p class="text-sm text-zinc-500">
          Role grants and quota changes. Previously unrecorded — the <code>admin_audit_events</code>
          table existed with no writer.
        </p>

        <div :if={@admin_events == []} class="text-sm text-zinc-500">Nothing yet.</div>

        <table
          :if={@admin_events != []}
          class="w-full text-sm bg-white rounded shadow border border-zinc-200"
        >
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">When</th>
              <th class="px-4 py-2">Action</th>
              <th class="px-4 py-2">Target</th>
              <th class="px-4 py-2">Detail</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={e <- @admin_events} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-2 text-xs text-zinc-500">{format_ts(e.inserted_at)}</td>
              <td class="px-4 py-2 font-mono text-xs">{e.event_type}</td>
              <td class="px-4 py-2 font-mono text-xs">{e.metadata["email"]}</td>
              <td class="px-4 py-2 text-xs text-zinc-500">
                <span :if={e.metadata["from"] != nil}>
                  {e.metadata["from"]} &rarr; {e.metadata["to"]}
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </div>
    """
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

  # Share of a provider's paid time with no turn in flight. Zero active time
  # is 0.0 rather than a division by zero — nothing running is not "all idle".
  defp idle_share(%{active_seconds: 0}), do: 0.0
  defp idle_share(%{active_seconds: active, idle_seconds: idle}), do: idle / active

  # Which provider a tenant's sandbox minutes ran on, for the usage cell's
  # tooltip. Empty when the tenant had no sandbox time, so the attribute
  # renders as nothing rather than as an empty tooltip.
  defp provider_split(by_provider) when map_size(by_provider) == 0, do: nil

  defp provider_split(by_provider) do
    by_provider
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {provider, minutes} -> "#{provider} #{round(minutes)}m" end)
  end

  defp format_hours(h) when h < 1, do: "#{round(h * 60)}m"
  defp format_hours(h) when h < 48, do: "#{Float.round(h * 1.0, 1)}h"
  defp format_hours(h), do: "#{Float.round(h / 24, 1)}d"
end
