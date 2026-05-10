defmodule AgentOnDemandWeb.AuditLive.Index do
  use AgentOnDemandWeb, :live_view

  # on_mount hook provided by phase-3-foundation's auth slice.
  # Audit log is admin-only; the auth hook enforces login, and the
  # router pipeline will enforce admin role once that is added.
  on_mount {AgentOnDemandWeb.UserAuth, :require_authenticated_user}

  alias AgentOnDemand.Audit

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, 5_000)

    {:ok,
     socket
     |> assign(:page_title, "Audit log")
     |> assign(:events, Audit.list_recent(200))}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, 5_000)
    {:noreply, assign(socket, :events, Audit.list_recent(200))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <h1 class="text-2xl font-semibold">Audit log</h1>
      <p class="text-sm text-zinc-500">Last 200 state-changing API calls. Updates every 5s.</p>

      <div :if={@events == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500">
        No events yet.
      </div>

      <table :if={@events != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200 font-mono">
        <thead class="text-left text-zinc-500 border-b border-zinc-200">
          <tr>
            <th class="px-3 py-2">when</th>
            <th class="px-3 py-2">actor</th>
            <th class="px-3 py-2">action</th>
            <th class="px-3 py-2">resource</th>
            <th class="px-3 py-2">status</th>
            <th class="px-3 py-2">ip</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={e <- @events} class="border-b border-zinc-100 last:border-0">
            <td class="px-3 py-1.5 text-zinc-500 text-xs">{format_ts(e.inserted_at)}</td>
            <td class="px-3 py-1.5">{e.actor || "—"}</td>
            <td class="px-3 py-1.5">{e.action}</td>
            <td class="px-3 py-1.5">
              {e.resource_type}
              <span :if={e.resource_id} class="text-zinc-400">/{String.slice(e.resource_id, 0, 8)}</span>
            </td>
            <td class="px-3 py-1.5">{e.metadata["status"] || "—"}</td>
            <td class="px-3 py-1.5 text-zinc-500">{e.request_ip || "—"}</td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_ts(nil), do: ""
  defp format_ts(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
end
