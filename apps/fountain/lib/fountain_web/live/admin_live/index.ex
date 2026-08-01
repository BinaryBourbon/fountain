defmodule FountainWeb.AdminLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Accounts, Conversations, Quotas}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
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
          event_type: if(new_role == "admin", do: "admin.role.granted", else: "admin.role.revoked"),
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

  defp assign_users(socket) do
    users =
      Enum.map(Accounts.list_users(), fn u ->
        Map.put(u, :active_sandboxes, Quotas.active_sandbox_count(u.id))
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
              <td class="px-4 py-2 text-right">
                <button phx-click="toggle_admin" phx-value-id={u.id}
                  data-confirm={"Toggle admin for #{u.email}?"}
                  class="text-xs text-zinc-600 hover:text-zinc-900 underline">
                  {if u.role == "admin", do: "Remove admin", else: "Make admin"}
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

  defp sandbox_status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  defp sandbox_status_color("ready"), do: "bg-green-100 text-green-800 border-green-200"
  defp sandbox_status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"
  defp sandbox_status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  defp format_date(nil), do: ""
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")

  defp format_ts(nil), do: ""
  defp format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
end
