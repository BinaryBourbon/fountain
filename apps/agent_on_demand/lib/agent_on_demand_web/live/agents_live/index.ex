defmodule AgentOnDemandWeb.AgentsLive.Index do
  use AgentOnDemandWeb, :live_view

  # on_mount hook provided by phase-3-foundation's auth slice.
  # Assigns current_user to socket; redirects unauthenticated sessions to /login.
  on_mount {AgentOnDemandWeb.UserAuth, :require_authenticated_user}

  alias AgentOnDemand.Agents
  alias AgentOnDemand.Agents.Agent

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id
    all_agents = Agents.list_agents(user_id)

    {:ok,
     socket
     |> assign(:page_title, "Agents")
     |> assign(:agents, all_agents)
     |> assign(:facet_counts, compute_facets(all_agents))
     |> assign(:all_environments, extract_environments(all_agents))
     |> assign(:filter_search, "")
     |> assign(:filter_runtimes, [])
     |> assign(:filter_env_ids, [])
     |> assign(:filter_has_skills, false)
     |> assign(:filter_has_mcp, false)}
  end

  @impl true
  def handle_event("filter", params, socket) do
    user_id = socket.assigns.current_user.id
    search = params |> Map.get("search", "") |> String.trim()
    runtimes = Map.get(params, "runtimes", [])
    env_ids = Map.get(params, "env_ids", [])
    has_skills = Map.has_key?(params, "has_skills")
    has_mcp = Map.has_key?(params, "has_mcp")

    filters = [
      search: search,
      runtimes: runtimes,
      env_ids: env_ids,
      has_skills: has_skills,
      has_mcp: has_mcp
    ]

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:filter_runtimes, runtimes)
     |> assign(:filter_env_ids, env_ids)
     |> assign(:filter_has_skills, has_skills)
     |> assign(:filter_has_mcp, has_mcp)
     |> assign(:agents, Agents.list_agents(user_id, filters))}
  end

  @impl true
  def handle_event("clear_filters", _params, socket) do
    user_id = socket.assigns.current_user.id

    {:noreply,
     socket
     |> assign(:filter_search, "")
     |> assign(:filter_runtimes, [])
     |> assign(:filter_env_ids, [])
     |> assign(:filter_has_skills, false)
     |> assign(:filter_has_mcp, false)
     |> assign(:agents, Agents.list_agents(user_id))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    user_id = socket.assigns.current_user.id
    agent = Agents.get_agent!(id, user_id)
    {:ok, _} = Agents.delete_agent(agent, user_id)

    all_agents = Agents.list_agents(user_id)
    filters = current_filters(socket.assigns)

    {:noreply,
     socket
     |> assign(:agents, Agents.list_agents(user_id, filters))
     |> assign(:facet_counts, compute_facets(all_agents))
     |> assign(:all_environments, extract_environments(all_agents))
     |> put_flash(:info, "Deleted #{agent.name}")}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="flex gap-6 items-start">
      <%!-- Filter sidebar --%>
      <aside class="w-52 shrink-0 space-y-5">
        <form phx-change="filter" phx-submit="filter" class="space-y-5">
          <%!-- Search --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Search</p>
            <input
              type="text"
              name="search"
              value={@filter_search}
              phx-debounce="200"
              placeholder="Agent name…"
              class="w-full rounded border border-zinc-300 px-2 py-1 text-sm focus:outline-none focus:border-zinc-500 bg-white"
            />
          </div>

          <%!-- Runtime facet --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Runtime</p>
            <div class="space-y-1.5">
              <label :for={rt <- Agent.runtimes()} class="flex items-center justify-between gap-2 text-sm cursor-pointer">
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="runtimes[]"
                    value={rt}
                    checked={rt in @filter_runtimes}
                    class="rounded border-zinc-300"
                  />
                  {rt}
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.runtimes, rt, 0)}</span>
              </label>
            </div>
          </div>

          <%!-- Environment facet --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Environment</p>
            <div class="space-y-1.5">
              <label class="flex items-center justify-between gap-2 text-sm cursor-pointer">
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="env_ids[]"
                    value="none"
                    checked={"none" in @filter_env_ids}
                    class="rounded border-zinc-300"
                  />
                  <span class="italic text-zinc-400">None</span>
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.env_ids, "none", 0)}</span>
              </label>
              <label
                :for={env <- @all_environments}
                class="flex items-center justify-between gap-2 text-sm cursor-pointer"
              >
                <span class="flex items-center gap-1.5">
                  <input
                    type="checkbox"
                    name="env_ids[]"
                    value={env.id}
                    checked={env.id in @filter_env_ids}
                    class="rounded border-zinc-300"
                  />
                  {env.name}
                </span>
                <span class="text-xs text-zinc-400">{Map.get(@facet_counts.env_ids, env.id, 0)}</span>
              </label>
            </div>
          </div>

          <%!-- Capability facets --%>
          <div>
            <p class="text-xs font-semibold text-zinc-500 uppercase tracking-wide mb-1.5">Capabilities</p>
            <div class="space-y-1.5">
              <label class="flex items-center gap-1.5 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="has_skills"
                  value="true"
                  checked={@filter_has_skills}
                  class="rounded border-zinc-300"
                />
                Has skills
              </label>
              <label class="flex items-center gap-1.5 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="has_mcp"
                  value="true"
                  checked={@filter_has_mcp}
                  class="rounded border-zinc-300"
                />
                Has MCP servers
              </label>
            </div>
          </div>
        </form>

        <button
          :if={filters_active?(assigns)}
          phx-click="clear_filters"
          class="text-xs text-zinc-400 hover:text-zinc-700 underline underline-offset-2"
        >
          Clear all filters
        </button>
      </aside>

      <%!-- Main content --%>
      <div class="flex-1 min-w-0 space-y-4">
        <div class="flex items-center justify-between">
          <h1 class="text-2xl font-semibold">Agents</h1>
          <.link navigate={~p"/agents/new"}><.btn>+ New agent</.btn></.link>
        </div>

        <div
          :if={@agents == [] and not filters_active?(assigns)}
          class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
        >
          No agents yet.
        </div>

        <div
          :if={@agents == [] and filters_active?(assigns)}
          class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500"
        >
          No agents match the current filters.
        </div>

        <table :if={@agents != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
          <thead class="text-left text-zinc-500 border-b border-zinc-200">
            <tr>
              <th class="px-4 py-2">Name</th>
              <th class="px-4 py-2">Runtime</th>
              <th class="px-4 py-2">Model</th>
              <th class="px-4 py-2">Env</th>
              <th class="px-4 py-2"></th>
            </tr>
          </thead>
          <tbody>
            <tr :for={a <- @agents} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
              <td class="px-4 py-2 font-medium">{a.name}</td>
              <td class="px-4 py-2 text-zinc-600">{a.runtime}</td>
              <td class="px-4 py-2 text-zinc-600 font-mono text-xs">{a.model}</td>
              <td class="px-4 py-2 text-zinc-600">{env_name(a.environment)}</td>
              <td class="px-4 py-2 text-right space-x-2">
                <.link navigate={~p"/agents/#{a.id}/edit"}><.btn_secondary>Edit</.btn_secondary></.link>
                <.btn_danger phx-click="delete" phx-value-id={a.id} data-confirm="Delete agent?">Delete</.btn_danger>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp env_name(nil), do: "—"
  defp env_name(env), do: env.name

  defp compute_facets(agents) do
    runtimes = Enum.frequencies_by(agents, & &1.runtime)

    env_ids =
      Enum.frequencies_by(agents, fn a ->
        if a.environment_id, do: a.environment_id, else: "none"
      end)

    %{runtimes: runtimes, env_ids: env_ids}
  end

  defp extract_environments(agents) do
    agents
    |> Enum.map(& &1.environment)
    |> Enum.filter(& &1)
    |> Enum.uniq_by(& &1.id)
    |> Enum.sort_by(& &1.name)
  end

  defp current_filters(assigns) do
    [
      search: assigns.filter_search,
      runtimes: assigns.filter_runtimes,
      env_ids: assigns.filter_env_ids,
      has_skills: assigns.filter_has_skills,
      has_mcp: assigns.filter_has_mcp
    ]
  end

  defp filters_active?(assigns) do
    assigns.filter_search != "" or
      assigns.filter_runtimes != [] or
      assigns.filter_env_ids != [] or
      assigns.filter_has_skills or
      assigns.filter_has_mcp
  end
end
