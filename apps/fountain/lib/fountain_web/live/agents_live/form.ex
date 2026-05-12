defmodule FountainWeb.AgentsLive.Form do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Agents, Environments}
  alias Fountain.Agents.Agent

  @impl true
  def mount(params, _session, socket) do
    user_id = socket.assigns.current_user.id
    envs = Environments.list_environments(user_id)
    {agent, action} = load(params, user_id)

    {:ok,
     socket
     |> assign(:page_title, page_title(action))
     |> assign(:user_id, user_id)
     |> assign(:envs, envs)
     |> assign(:action, action)
     |> assign(:agent, agent)
     |> assign(:form, agent_to_form(agent))
     |> assign(:errors, %{})}
  end

  defp load(%{"id" => id}, user_id), do: {Agents.get_agent!(id, user_id), :edit}
  defp load(_, _user_id), do: {%Agent{}, :new}

  defp page_title(:new), do: "New agent"
  defp page_title(:edit), do: "Edit agent"

  defp agent_to_form(%Agent{} = a) do
    %{
      "name" => a.name || "",
      "description" => a.description || "",
      "system" => a.system || "",
      "model" => a.model || "anthropic/claude-sonnet-4-6",
      "runtime" => a.runtime || "claude",
      "environment_id" => a.environment_id || "",
      "skills_json" => Jason.encode!(a.skills || [], pretty: true),
      "mcp_servers_json" => Jason.encode!(a.mcp_servers || %{}, pretty: true)
    }
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    {:noreply, assign(socket, :form, params)}
  end

  def handle_event("submit", %{"agent" => params}, socket) do
    with {:ok, mcp} <- parse_mcp(params),
         {:ok, skills} <- parse_skills(params) do
      attrs =
        params
        |> Map.put("skills", skills)
        |> Map.put("mcp_servers", mcp)
        |> Map.put("user_id", socket.assigns.user_id)
        |> Map.drop(["skills_json", "mcp_servers_json"])
        |> nil_if_blank("environment_id")

      save(socket, attrs)
    else
      {:error, field, msg} ->
        {:noreply, assign(socket, :errors, %{field => msg})}
    end
  end

  defp save(%{assigns: %{action: :new}} = socket, attrs) do
    case Agents.create_agent(attrs) do
      {:ok, _agent} ->
        {:noreply, socket |> put_flash(:info, "Agent created") |> push_navigate(to: ~p"/agents")}

      {:error, cs} ->
        {:noreply, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp save(%{assigns: %{action: :edit, agent: agent}} = socket, attrs) do
    case Agents.update_agent(agent, attrs) do
      {:ok, _agent} ->
        {:noreply, socket |> put_flash(:info, "Agent updated") |> push_navigate(to: ~p"/agents")}

      {:error, cs} ->
        {:noreply, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp parse_skills(%{"skills_json" => v}) when v in [nil, ""], do: {:ok, []}

  defp parse_skills(%{"skills_json" => json}) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> {:ok, list}
      {:ok, _} -> {:error, "skills_json", "must be a JSON array"}
      {:error, %Jason.DecodeError{} = e} ->
        {:error, "skills_json", "invalid JSON: #{Exception.message(e)}"}
    end
  end

  defp parse_mcp(%{"mcp_servers_json" => v}) when v in [nil, ""], do: {:ok, %{}}

  defp parse_mcp(%{"mcp_servers_json" => json}) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> {:ok, m}
      {:ok, _} -> {:error, "mcp_servers_json", "must be a JSON object"}
      {:error, %Jason.DecodeError{} = e} ->
        {:error, "mcp_servers_json", "invalid JSON: #{Exception.message(e)}"}
    end
  end

  defp nil_if_blank(map, key),
    do: Map.update(map, key, nil, fn v -> if v in [nil, ""], do: nil, else: v end)

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Map.new(fn {k, [first | _]} -> {to_string(k), first} end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <h1 class="text-2xl font-semibold">{page_title(@action)}</h1>

      <form phx-change="validate" phx-submit="submit" class="space-y-4 bg-white rounded shadow p-6 border border-zinc-200">
        <.input id="name" name="agent[name]" label="Name" value={@form["name"]} autofocus required />
        <.error_msg field="name" errors={@errors}/>

        <.input id="description" name="agent[description]" label="Description" value={@form["description"]} />

        <.input id="system" name="agent[system]" type="textarea" rows="6"
          label="System prompt" value={@form["system"]} placeholder="You are a focused subagent..."/>

        <div class="grid grid-cols-2 gap-3">
          <div class="space-y-1">
            <label class="block text-sm font-medium text-zinc-700">Runtime</label>
            <select name="agent[runtime]" class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
              <option :for={r <- ~w(claude codex gemini opencode)} value={r} selected={@form["runtime"] == r}>{r}</option>
            </select>
          </div>
          <.input id="model" name="agent[model]" label="Model" value={@form["model"]}
            placeholder="anthropic/claude-sonnet-4-6" required/>
        </div>
        <.error_msg field="model" errors={@errors}/>

        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Environment</label>
          <select name="agent[environment_id]" class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
            <option value="">— none —</option>
            <option :for={e <- @envs} value={e.id} selected={@form["environment_id"] == e.id}>{e.name}</option>
          </select>
        </div>

        <.input id="skills_json" name="agent[skills_json]" type="textarea" rows="6"
          label="Skills (JSON array)"
          value={@form["skills_json"]}
          placeholder={~s([{"source": "anthropics/skills", "name": "frontend-design"}])}/>
        <.error_msg field="skills_json" errors={@errors}/>
        <div class="text-xs text-zinc-500 -mt-2 space-y-2">
          <p>
            Each entry is either inline
            (<code>{~s({"name": "...", "content": "<SKILL.md body>"})}</code>)
            or a GitHub skill via
            <a href="https://skills.sh" target="_blank" class="underline">skills.sh</a>
            (<code>{~s({"source": "owner/repo", "name": "<optional>"})}</code>).
            <.link navigate={~p"/help/skills"} class="underline">Skills help →</.link>
          </p>
          <div class="rounded border border-blue-200 bg-blue-50 px-3 py-2 text-blue-900 leading-relaxed">
            <strong>Always included:</strong>
            the built-in <code>fountain</code> skill is automatically mounted in every
            conversation — no need to declare it. It gives the agent
            <code>$FOUNTAIN_TOKEN</code>, <code>$FOUNTAIN_BASE_URL</code>, and
            <code>$FOUNTAIN_CONVERSATION_ID</code> so it can spawn and coordinate sub-agents.
          </div>
          <p>
            Common GitHub skills:
            <code>{~s({"source": "anthropics/skills", "name": "brainstorming"})}</code>
            ·
            <code>{~s({"source": "anthropics/skills", "name": "test-driven-development"})}</code>
            ·
            <code>{~s({"source": "anthropics/skills", "name": "systematic-debugging"})}</code>
          </p>
        </div>

        <.input id="mcp_servers_json" name="agent[mcp_servers_json]" type="textarea" rows="6"
          label="MCP servers (JSON object)" value={@form["mcp_servers_json"]}/>
        <.error_msg field="mcp_servers_json" errors={@errors}/>

        <div class="flex gap-2">
          <.btn type="submit" phx-disable-with="Saving…">Save</.btn>
          <.link navigate={~p"/agents"}><.btn_secondary>Cancel</.btn_secondary></.link>
        </div>
      </form>
    </div>
    """
  end

  attr :field, :string, required: true
  attr :errors, :map, required: true

  defp error_msg(assigns) do
    ~H"""
    <p :if={Map.has_key?(@errors, @field)} class="text-rose-600 text-xs">{Map.get(@errors, @field)}</p>
    """
  end
end
