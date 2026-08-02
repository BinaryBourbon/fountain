defmodule FountainWeb.AdminLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Accounts, Billing, Conversations, Quotas}
  alias Fountain.Accounts.Deletion

  @usage_window_days 30

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> FountainWeb.Audited.put_client_ip()
     |> assign(:page_title, "Admin")
     |> assign_users()
     |> assign(:sandboxes, Conversations.list_sandboxes_admin())
     |> assign(:admin_events, Fountain.Audit.list_recent_admin(25))}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)

    {:noreply,
     socket
     |> assign_users()
     |> assign(:sandboxes, Conversations.list_sandboxes_admin())
     |> assign(:admin_events, Fountain.Audit.list_recent_admin(25))}
  end

  @impl true
  def handle_event("toggle_admin", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    new_role = if user.role == "admin", do: "user", else: "admin"

    case Accounts.update_user_role(user, new_role) do
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

  # The concurrency cap is the only lever for a noisy or abusive tenant
  # (ADR 0005). Without this it is adjustable only with direct database access,
  # which makes it useless in an incident.
  @impl true
  def handle_event("set_sandbox_limit", %{"user_id" => id, "limit" => raw}, socket) do
    with {limit, ""} <- Integer.parse(String.trim(raw)),
         user = Accounts.get_user!(id),
         {:ok, _} <- Accounts.update_sandbox_limit(user, limit) do
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
      _ -> {:noreply, put_flash(socket, :error, "Limit must be a whole number of 0 or more")}
    end
  end

  @impl true
  def handle_event("extend_trial", %{"user_id" => id, "days" => raw}, socket) do
    with {days, ""} when days > 0 <- Integer.parse(String.trim(raw)),
         user = Accounts.get_user!(id),
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

      _ ->
        {:noreply, put_flash(socket, :error, "Days must be a whole number of 1 or more")}
    end
  end

  @impl true
  def handle_event("toggle_comp", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)

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
         |> assign(:sandboxes, Conversations.list_sandboxes_admin())
         |> assign_users()
         |> put_flash(:info, msg)}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Sandbox not found")}
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
      user = Accounts.get_user!(id)

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
           |> assign(:sandboxes, Conversations.list_sandboxes_admin())
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
  end

  defp assign_users(socket) do
    now = DateTime.utc_now()

    # Upper bound one second ahead: the column is second-precision, so a bound
    # of `now` loses its sub-second part in the cast and excludes events
    # recorded within the current second.
    usage =
      Billing.usage_summaries(
        DateTime.add(now, -@usage_window_days, :day),
        DateTime.add(now, 1, :second)
      )
    no_usage = %{conversations: 0, turns: 0, sandbox_minutes: 0.0}

    users =
      Enum.map(Accounts.list_users(), fn u ->
        u
        |> Map.put(:active_sandboxes, Quotas.active_sandbox_count(u.id))
        |> Map.put(:usage, Map.get(usage, u.id, no_usage))
      end)

    assign(socket, :users, users)
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
        <h2 class="text-lg font-medium">Users ({length(@users)})</h2>
        <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">Email</th>
              <th class="px-4 py-2">Role</th>
              <th class="px-4 py-2">Billing</th>
              <th class="px-4 py-2" title="Last 30 days: conversations / turns / sandbox minutes">
                Usage 30d
              </th>
              <th class="px-4 py-2">Sandboxes</th>
              <th class="px-4 py-2">Onboarding</th>
              <th class="px-4 py-2">Joined</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={u <- @users} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
              <td class="px-4 py-2 font-mono text-xs">{u.email}</td>
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
              <td class="px-4 py-2">
                <div class="space-y-1">
                  <div class="flex items-center gap-2">
                    <span class={[
                      "inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border",
                      subscription_status_color(u.subscription_status)
                    ]}>
                      {u.subscription_status}
                    </span>
                    <span :if={u.subscription_status == "trialing" and u.trial_ends_at} class="text-xs text-zinc-500">
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
                  </div>
                </div>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500 tabular-nums whitespace-nowrap">
                {u.usage.conversations}c · {u.usage.turns}t · {round(u.usage.sandbox_minutes)}m
              </td>
              <td class="px-4 py-2">
                <form phx-submit="set_sandbox_limit" id={"sandbox-limit-#{u.id}"} class="flex items-center gap-1">
                  <input type="hidden" name="user_id" value={u.id} />
                  <span class={[
                    "text-xs tabular-nums",
                    if(u.active_sandboxes >= u.max_concurrent_sandboxes,
                      do: "text-red-600 font-medium",
                      else: "text-zinc-500"
                    )
                  ]}>{u.active_sandboxes} /</span>
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
              <td class="px-4 py-2 text-zinc-500 text-xs">{format_date(u.inserted_at)}</td>
              <td class="px-4 py-2 text-right space-x-3">
                <button phx-click="toggle_admin" phx-value-id={u.id}
                  data-confirm={"Toggle admin for #{u.email}?"}
                  class="text-xs text-zinc-600 hover:text-zinc-900 underline">
                  {if u.role == "admin", do: "Remove admin", else: "Make admin"}
                </button>
                <button
                  :if={u.id != @current_user.id}
                  phx-click="delete_user"
                  phx-value-id={u.id}
                  data-confirm={"Permanently delete #{u.email}? This cancels their subscription, destroys their sandboxes and erases their data. It cannot be undone."}
                  class="text-xs text-red-600 hover:text-red-800 underline">
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Active sandboxes ({length(@sandboxes)})</h2>

        <div :if={@sandboxes == []} class="text-sm text-zinc-500">No active sandboxes.</div>

        <table :if={@sandboxes != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200 font-mono">
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">ID</th>
              <th class="px-4 py-2">Status</th>
              <th class="px-4 py-2">Conversations</th>
              <th class="px-4 py-2">Started</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={s <- @sandboxes} class="border-b border-zinc-100 last:border-0">
              <td class="px-4 py-2 text-xs">{String.slice(s.id, 0, 8)}</td>
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
                    navigate={~p"/conversations/#{c.id}"}
                    class="hover:underline"
                  >{String.slice(c.id, 0, 8)}</.link>
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
          Role grants and quota changes. Previously unrecorded — the
          <code>admin_audit_events</code> table existed with no writer.
        </p>

        <div :if={@admin_events == []} class="text-sm text-zinc-500">Nothing yet.</div>

        <table :if={@admin_events != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
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

  defp subscription_status_color("active"), do: "bg-green-100 text-green-800 border-green-200"
  defp subscription_status_color("trialing"), do: "bg-blue-100 text-blue-800 border-blue-200"
  defp subscription_status_color("comped"), do: "bg-purple-100 text-purple-800 border-purple-200"
  defp subscription_status_color("past_due"), do: "bg-amber-100 text-amber-800 border-amber-200"
  defp subscription_status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  defp sandbox_status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  defp sandbox_status_color("ready"), do: "bg-green-100 text-green-800 border-green-200"
  defp sandbox_status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"
  defp sandbox_status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  defp format_date(nil), do: ""
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_ts(nil), do: ""
  defp format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
