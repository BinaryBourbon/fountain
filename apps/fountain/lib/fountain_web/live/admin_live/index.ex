defmodule FountainWeb.AdminLive.Index do
  use FountainWeb, :live_view

  alias Fountain.{Accounts, Conversations}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, 10_000)

    {:ok,
     socket
     |> assign(:page_title, "Admin")
     |> assign(:users, Accounts.list_users())
     |> assign(:sandboxes, Conversations.list_sandboxes_admin())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 10_000)

    {:noreply,
     socket
     |> assign(:users, Accounts.list_users())
     |> assign(:sandboxes, Conversations.list_sandboxes_admin())}
  end

  @impl true
  def handle_event("toggle_admin", %{"id" => id}, socket) do
    user = Accounts.get_user!(id)
    new_role = if user.role == "admin", do: "user", else: "admin"

    case Accounts.update_user_role(user, new_role) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:users, Accounts.list_users())
         |> put_flash(:info, "Role updated")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update role")}
    end
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
              <th class="px-4 py-2">Conversation</th>
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
                <.link navigate={~p"/conversations/#{s.conversation_id}"} class="hover:underline">
                  {String.slice(s.conversation_id, 0, 8)}
                </.link>
              </td>
              <td class="px-4 py-2 text-xs text-zinc-500">{format_ts(s.inserted_at)}</td>
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
