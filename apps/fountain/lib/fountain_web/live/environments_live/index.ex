defmodule FountainWeb.EnvironmentsLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Environments

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:page_title, "Environments")
     |> assign(:user_id, user_id)
     |> assign(:filter_search, "")
     |> assign(:envs, load_envs(user_id, ""))}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    search = String.trim(search)

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:envs, load_envs(socket.assigns.user_id, search))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    env = Environments.get_environment!(id, socket.assigns.user_id)
    {:ok, _} = Environments.delete_environment(env)

    {:noreply,
     socket
     |> assign(:envs, load_envs(socket.assigns.user_id, socket.assigns.filter_search))
     |> put_flash(:info, "Deleted #{env.name}")}
  end

  defp load_envs(user_id, search) do
    envs = Environments.list_environments_with_counts(user_id)

    if search == "" do
      envs
    else
      term = String.downcase(search)
      Enum.filter(envs, fn e -> String.contains?(String.downcase(e.name), term) end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Environments</h1>
        <.link navigate={~p"/environments/new"}><.btn>+ New environment</.btn></.link>
      </div>

      <%!-- Search bar --%>
      <form phx-change="search" phx-submit="search">
        <input
          type="text"
          name="search"
          value={@filter_search}
          phx-debounce="200"
          placeholder="Search environments…"
          class="w-64 rounded border px-3 py-1.5 text-sm focus:outline-none"
          style="background:#111;border-color:#2a2a2a;color:#e5e7eb;"
        />
      </form>

      <%!-- Empty state — no envs at all --%>
      <div
        :if={@envs == [] and @filter_search == ""}
        class="rounded-lg p-10 text-center"
        style="background:#0a0a0a;border:1px dashed #2a2a2a;"
      >
        <p class="text-sm" style="color:#6b7280;">No environments yet.</p>
        <p class="text-xs mt-1" style="color:#374151;">Create one to configure packages, secrets, and a setup script for your agents.</p>
      </div>

      <%!-- Empty state — search returned nothing --%>
      <div
        :if={@envs == [] and @filter_search != ""}
        class="rounded-lg p-8 text-center"
        style="background:#0a0a0a;border:1px dashed #2a2a2a;"
      >
        <p class="text-sm" style="color:#6b7280;">No environments match <span class="font-mono" style="color:#9ca3af;">"{@filter_search}"</span>.</p>
      </div>

      <%!-- Table --%>
      <table
        :if={@envs != []}
        class="w-full text-sm rounded-lg overflow-hidden"
        style="background:#0a0a0a;border:1px solid #1a1a1a;"
      >
        <thead style="border-bottom:1px solid #222;">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Name</th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Network</th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Setup</th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Stats</th>
            <th class="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={e <- @envs}
            class="hover:bg-[#0d1117] transition-colors duration-150"
            style="border-bottom:1px solid #161616;"
          >
            <td class="px-4 py-3 font-medium" style="color:#e5e7eb;">{e.name}</td>
            <td class="px-4 py-3">
              <span
                class="inline-flex items-center gap-1 px-2 py-1 rounded text-xs font-semibold"
                style={networking_badge_style(e.networking_type)}
              >
                <span class="w-1.5 h-1.5 rounded-full" style="background:currentColor;"></span>
                {e.networking_type}
              </span>
            </td>
            <td class="px-4 py-3">
              <span
                :if={e.setup_script != ""}
                class="font-mono text-xs block truncate max-w-xs"
                style="color:#4b5563;"
                title={e.setup_script}
              >{truncate(e.setup_script, 48)}</span>
              <span :if={e.setup_script == ""} style="color:#374151;">—</span>
            </td>
            <td class="px-4 py-3">
              <div class="flex items-center gap-1.5 flex-wrap">
                <span
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                  style={stat_badge_style(:secrets, e.secret_count)}
                  title={"#{e.secret_count} secrets"}
                >🔑 {e.secret_count}</span>
                <span
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                  style={stat_badge_style(:agents, e.agent_count)}
                  title={"#{e.agent_count} agents"}
                >⚡ {e.agent_count}</span>
                <span
                  :if={map_size(e.packages) > 0}
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                  style="background:#150d25;color:#a78bfa;border:1px solid #2a1a4a;"
                  title={"#{map_size(e.packages)} packages"}
                >📦 {map_size(e.packages)}</span>
                <span
                  :if={length(e.repositories) > 0}
                  class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                  style="background:#0d1525;color:#93c5fd;border:1px solid #1a2a4a;"
                  title={"#{length(e.repositories)} repos"}
                >⑂ {length(e.repositories)}</span>
              </div>
            </td>
            <td class="px-4 py-3 text-right">
              <div class="inline-flex gap-1">
                <.link navigate={~p"/environments/#{e.id}/edit"}>
                  <button
                    class="px-2 py-1 rounded text-xs cursor-pointer"
                    style="background:#1a1a1a;border:1px solid #2a2a2a;color:#9ca3af;"
                  >Edit</button>
                </.link>
                <button
                  class="px-2 py-1 rounded text-xs cursor-pointer"
                  style="background:#1a0d0d;border:1px solid #3a1a1a;color:#f87171;"
                  phx-click="delete"
                  phx-value-id={e.id}
                  data-confirm="Delete environment?"
                >Delete</button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp truncate(str, max) when byte_size(str) <= max, do: str
  defp truncate(str, max), do: binary_part(str, 0, max) <> "…"

  defp networking_badge_style("unrestricted"),
    do: "background:#0d1f0d;color:#6ee7b7;border:1px solid #1a3a1a;"

  defp networking_badge_style("limited"),
    do: "background:#1a1200;color:#fbbf24;border:1px solid #3a2a00;"

  defp networking_badge_style(_),
    do: "background:#1a1a1a;color:#9ca3af;border:1px solid #2a2a2a;"

  defp stat_badge_style(_type, 0),
    do: "background:#111;color:#374151;border:1px solid #1f1f1f;"

  defp stat_badge_style(:secrets, _),
    do: "background:#1a1200;color:#fbbf24;border:1px solid #3a2a00;"

  defp stat_badge_style(:agents, _),
    do: "background:#0d1f0d;color:#6ee7b7;border:1px solid #1a3a1a;"
end
