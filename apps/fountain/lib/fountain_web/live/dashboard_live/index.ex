defmodule FountainWeb.DashboardLive.Index do
  use FountainWeb, :live_view

  alias Fountain.{Agents, Conversations}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    recent_convs = Conversations.list_conversations(user.id) |> Enum.take(5)
    agents = Agents.list_agents(user.id, [])

    {:ok,
     socket
     |> assign(:page_title, "Dashboard")
     |> assign(:recent_conversations, recent_convs)
     |> assign(:agent_count, length(agents))
     |> assign(:show_onboarding_banner, not is_nil(user.onboarding_completed_at))}
  end

  @impl true
  def handle_event("dismiss_banner", _params, socket) do
    {:noreply, assign(socket, :show_onboarding_banner, false)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div :if={@show_onboarding_banner}
        class="rounded bg-green-50 border border-green-200 px-4 py-3 flex items-center justify-between">
        <span class="text-sm text-green-800">
          You're up and running. Explore Environments, Agents, and Vaults in the sidebar.
        </span>
        <button phx-click="dismiss_banner"
          class="text-green-600 hover:text-green-800 text-xs underline ml-4">
          Dismiss
        </button>
      </div>

      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Dashboard</h1>
        <.link navigate={~p"/conversations/new"}><.btn>+ New conversation</.btn></.link>
      </div>

      <div class="grid grid-cols-3 gap-4">
        <.link navigate={~p"/"}
          class="rounded border border-zinc-200 bg-white shadow p-4 hover:bg-zinc-50 block">
          <p class="text-xs text-zinc-500 uppercase tracking-wide">Recent conversations</p>
          <p class="text-2xl font-semibold mt-1">{length(@recent_conversations)}</p>
        </.link>
        <.link navigate={~p"/agents"}
          class="rounded border border-zinc-200 bg-white shadow p-4 hover:bg-zinc-50 block">
          <p class="text-xs text-zinc-500 uppercase tracking-wide">Agents</p>
          <p class="text-2xl font-semibold mt-1">{@agent_count}</p>
        </.link>
        <.link navigate={~p"/environments"}
          class="rounded border border-zinc-200 bg-white shadow p-4 hover:bg-zinc-50 block">
          <p class="text-xs text-zinc-500 uppercase tracking-wide">Environments</p>
          <p class="text-2xl font-semibold mt-1">→</p>
        </.link>
      </div>

      <div :if={@recent_conversations != []}>
        <h2 class="text-lg font-medium mb-2">Recent conversations</h2>
        <table class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <tbody>
            <tr :for={c <- @recent_conversations}
              class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
              <td class="px-4 py-2">
                <.link navigate={~p"/conversations/#{c.id}"} class="font-medium hover:underline">
                  {if c.agent, do: c.agent.name, else: "(no agent)"}
                </.link>
              </td>
              <td class="px-4 py-2"><.conversation_status_badge status={c.status} /></td>
              <td class="px-4 py-2 text-zinc-500 text-xs">{relative_time(c.updated_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>

      <div :if={@recent_conversations == []}
        class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500 space-y-2">
        <p>No conversations yet.</p>
        <.link navigate={~p"/conversations/new"} class="text-zinc-900 underline">
          Start your first conversation
        </.link>
      </div>
    </div>
    """
  end

  attr :status, :string, required: true

  defp conversation_status_badge(assigns) do
    color =
      case assigns.status do
        "ready" -> "bg-green-100 text-green-800 border-green-200"
        "running" -> "bg-blue-100 text-blue-800 border-blue-200"
        "pending" -> "bg-zinc-100 text-zinc-600 border-zinc-200"
        "starting" -> "bg-blue-50 text-blue-600 border-blue-200"
        "terminated" -> "bg-zinc-100 text-zinc-500 border-zinc-200"
        "failed" -> "bg-red-100 text-red-700 border-red-200"
        _ -> "bg-zinc-100 text-zinc-500 border-zinc-200"
      end

    assigns = assign(assigns, :color, color)

    ~H"""
    <span class={"inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium border #{@color}"}>
      {@status}
    </span>
    """
  end

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt))

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end
end
