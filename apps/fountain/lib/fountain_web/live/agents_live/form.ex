defmodule FountainWeb.AgentsLive.Form do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Agents, AvatarGenerator, Environments}
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
     |> assign(:errors, %{})
     |> assign(:skills, agent_to_skill_list(agent.skills || []))
     |> assign(:mcp_servers, agent_to_mcp_server_list(agent.mcp_servers || %{}))
     |> assign(:avatar_tab, :upload)
     |> assign(:avatar_base, "robot")
     |> assign(:avatar_mood, "serious")
     |> assign(:generating_avatar, false)
     |> assign(:generated_avatar_data, nil)
     |> assign(:generated_avatar_preview, nil)
     |> assign(:avatar_error, nil)
     |> allow_upload(:avatar,
       accept: ~w(image/jpeg image/png image/gif image/webp),
       max_entries: 1,
       max_file_size: 5_242_880
     )}
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
      "environment_id" => a.environment_id || ""
    }
  end

  defp agent_to_skill_list(skills) do
    Enum.map(skills, fn skill ->
      if Map.has_key?(skill, "content") or Map.has_key?(skill, :content) do
        %{
          "type" => "inline",
          "name" => skill["name"] || skill[:name] || "",
          "content" => skill["content"] || skill[:content] || "",
          "source" => ""
        }
      else
        %{
          "type" => "github",
          "source" => skill["source"] || skill[:source] || "",
          "name" => skill["name"] || skill[:name] || "",
          "content" => ""
        }
      end
    end)
  end

  defp agent_to_mcp_server_list(mcp_servers) do
    Enum.map(mcp_servers, fn {name, config} ->
      args_str = (config["args"] || []) |> Enum.join("\n")
      env_vars = (config["env"] || %{}) |> Enum.map(fn {k, v} -> %{"key" => k, "value" => v} end)
      %{"name" => name, "command" => config["command"] || "", "args" => args_str, "env_vars" => env_vars}
    end)
  end

  @impl true
  def handle_event("validate", %{"agent" => params}, socket) do
    skills = extract_skills_from_params(params, socket.assigns.skills)
    mcp_servers = extract_mcp_servers_from_params(params, socket.assigns.mcp_servers)
    {:noreply, socket |> assign(:form, params) |> assign(:skills, skills) |> assign(:mcp_servers, mcp_servers)}
  end

  def handle_event("add_skill", _, socket) do
    skills = socket.assigns.skills ++ [%{"type" => "github", "source" => "", "name" => "", "content" => ""}]
    {:noreply, assign(socket, :skills, skills)}
  end

  def handle_event("remove_skill", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {:noreply, assign(socket, :skills, List.delete_at(socket.assigns.skills, index))}
  end

  def handle_event("set_skill_type", %{"index" => index_str, "type" => type}, socket)
      when type in ["github", "inline"] do
    index = String.to_integer(index_str)
    skills = List.update_at(socket.assigns.skills, index, &Map.put(&1, "type", type))
    {:noreply, assign(socket, :skills, skills)}
  end

  def handle_event("add_mcp_server", _, socket) do
    servers =
      socket.assigns.mcp_servers ++
        [%{"name" => "", "command" => "", "args" => "", "env_vars" => []}]

    {:noreply, assign(socket, :mcp_servers, servers)}
  end

  def handle_event("remove_mcp_server", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    {:noreply, assign(socket, :mcp_servers, List.delete_at(socket.assigns.mcp_servers, index))}
  end

  def handle_event("add_mcp_env_var", %{"server" => server_idx_str}, socket) do
    server_idx = String.to_integer(server_idx_str)

    servers =
      List.update_at(socket.assigns.mcp_servers, server_idx, fn s ->
        Map.update(s, "env_vars", [%{"key" => "", "value" => ""}], fn evs ->
          evs ++ [%{"key" => "", "value" => ""}]
        end)
      end)

    {:noreply, assign(socket, :mcp_servers, servers)}
  end

  def handle_event("remove_mcp_env_var", %{"server" => server_idx_str, "index" => idx_str}, socket) do
    server_idx = String.to_integer(server_idx_str)
    idx = String.to_integer(idx_str)

    servers =
      List.update_at(socket.assigns.mcp_servers, server_idx, fn s ->
        Map.update(s, "env_vars", [], &List.delete_at(&1, idx))
      end)

    {:noreply, assign(socket, :mcp_servers, servers)}
  end

  def handle_event("cancel_upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :avatar, ref)}
  end

  def handle_event("remove_avatar", _, socket) do
    agent = socket.assigns.agent

    if agent.id do
      Agents.delete_avatar(agent)
      {:noreply, assign(socket, :agent, %{agent | avatar_media_type: nil})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("switch_avatar_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :avatar_tab, String.to_existing_atom(tab))}
  end

  def handle_event("set_avatar_base", %{"base" => base}, socket)
      when base in ["robot", "human", "alien"] do
    {:noreply, assign(socket, :avatar_base, base)}
  end

  def handle_event("set_avatar_mood", %{"mood" => mood}, socket)
      when mood in ["serious", "casual", "goofy"] do
    {:noreply, assign(socket, :avatar_mood, mood)}
  end

  def handle_event("generate_avatar", _params, socket) do
    user_id = socket.assigns.user_id
    base = socket.assigns.avatar_base
    mood = socket.assigns.avatar_mood

    socket =
      socket
      |> assign(:generating_avatar, true)
      |> assign(:avatar_error, nil)
      |> assign(:generated_avatar_data, nil)
      |> assign(:generated_avatar_preview, nil)

    {:noreply,
     start_async(socket, :generate_avatar, fn ->
       AvatarGenerator.generate(user_id, base, mood)
     end)}
  end

  def handle_event("discard_generated_avatar", _, socket) do
    {:noreply,
     socket
     |> assign(:generated_avatar_data, nil)
     |> assign(:generated_avatar_preview, nil)
     |> assign(:avatar_error, nil)}
  end

  def handle_event("submit", %{"agent" => params}, socket) do
    skills_list = extract_skills_from_params(params, socket.assigns.skills)
    mcp_servers_list = extract_mcp_servers_from_params(params, socket.assigns.mcp_servers)

    with :ok <- validate_skills_list(skills_list),
         :ok <- validate_mcp_servers(mcp_servers_list) do
      skills =
        Enum.map(skills_list, fn s ->
          case s["type"] do
            "github" ->
              m = %{"source" => s["source"] || ""}
              if (s["name"] || "") != "", do: Map.put(m, "name", s["name"]), else: m

            "inline" ->
              %{"name" => s["name"] || "", "content" => s["content"] || ""}

            _ ->
              nil
          end
        end)
        |> Enum.reject(&is_nil/1)

      mcp_map =
        Map.new(mcp_servers_list, fn s ->
          args =
            (s["args"] || "")
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          env_map =
            (s["env_vars"] || [])
            |> Map.new(fn %{"key" => k, "value" => v} -> {k, v} end)
            |> Map.reject(fn {k, _} -> k == "" end)

          config = %{"command" => s["command"] || ""}
          config = if args != [], do: Map.put(config, "args", args), else: config
          config = if map_size(env_map) > 0, do: Map.put(config, "env", env_map), else: config

          {s["name"] || "", config}
        end)
        |> Map.reject(fn {k, _} -> k == "" end)

      attrs =
        params
        |> Map.put("skills", skills)
        |> Map.put("mcp_servers", mcp_map)
        |> Map.put("user_id", socket.assigns.user_id)
        |> nil_if_blank("environment_id")

      case save(socket, attrs) do
        {:ok, socket} -> {:noreply, socket}
        {:error, socket} -> {:noreply, socket}
      end
    else
      {:error, field, msg} ->
        {:noreply, assign(socket, :errors, %{field => msg})}
    end
  end

  @impl true
  def handle_async(:generate_avatar, {:ok, {:ok, data}}, socket) do
    preview = "data:image/png;base64," <> Base.encode64(data)

    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:generated_avatar_data, data)
     |> assign(:generated_avatar_preview, preview)
     |> assign(:avatar_error, nil)}
  end

  def handle_async(:generate_avatar, {:ok, {:error, :no_openai_key}}, socket) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, "No OpenAI API key found. Add one in Settings \u2192 Credentials.")}
  end

  def handle_async(:generate_avatar, {:ok, {:error, reason}}, socket)
      when is_binary(reason) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, reason)}
  end

  def handle_async(:generate_avatar, {:ok, {:error, _reason}}, socket) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, "Avatar generation failed. Please try again.")}
  end

  def handle_async(:generate_avatar, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:generating_avatar, false)
     |> assign(:avatar_error, "Avatar generation failed. Please try again.")}
  end

  defp save(%{assigns: %{action: :new}} = socket, attrs) do
    case Agents.create_agent(attrs) do
      {:ok, agent} ->
        maybe_set_avatar(socket, agent)

        {:ok,
         socket
         |> put_flash(:info, "Agent created")
         |> push_navigate(to: ~p"/agents")}

      {:error, cs} ->
        {:error, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp save(%{assigns: %{action: :edit, agent: existing}} = socket, attrs) do
    case Agents.update_agent(existing, attrs) do
      {:ok, saved} ->
        maybe_set_avatar(socket, saved)

        {:ok,
         socket
         |> put_flash(:info, "Agent updated")
         |> push_navigate(to: ~p"/agents")}

      {:error, cs} ->
        {:error, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp maybe_set_avatar(socket, agent) do
    uploaded =
      consume_uploaded_entries(socket, :avatar, fn %{path: path}, entry ->
        data = File.read!(path)
        Agents.upload_avatar(agent, data, entry.client_type)
        {:ok, :uploaded}
      end)

    if uploaded == [] do
      case socket.assigns.generated_avatar_data do
        nil -> :ok
        data -> Agents.upload_avatar(agent, data, "image/png")
      end
    end
  end

  defp extract_skills_from_params(params, current_skills) do
    case params["skills"] do
      nil -> current_skills
      skills_map when is_map(skills_map) ->
        skills_map
        |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
        |> Enum.map(fn {_, s} -> s end)
      _ -> current_skills
    end
  end

  defp extract_mcp_servers_from_params(params, current_servers) do
    case params["mcp_servers"] do
      nil -> current_servers
      servers_map when is_map(servers_map) ->
        servers_map
        |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
        |> Enum.map(fn {_, s} ->
          env_vars =
            case s["env_vars"] do
              nil -> []
              evs when is_map(evs) ->
                evs
                |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
                |> Enum.map(fn {_, r} -> r end)
              _ -> []
            end
          Map.put(s, "env_vars", env_vars)
        end)
      _ -> current_servers
    end
  end

  defp validate_skills_list([]), do: :ok

  defp validate_skills_list(skills) do
    Enum.reduce_while(skills, :ok, fn skill, _acc ->
      case skill["type"] do
        "github" ->
          if (skill["source"] || "") == "" do
            {:halt, {:error, "skills_json", "each GitHub skill must have a source (owner/repo)"}}
          else
            {:cont, :ok}
          end

        "inline" ->
          cond do
            (skill["name"] || "") == "" ->
              {:halt, {:error, "skills_json", "each inline skill must have a name"}}

            (skill["content"] || "") == "" ->
              {:halt, {:error, "skills_json", "each inline skill must have content"}}

            true ->
              {:cont, :ok}
          end

        _ ->
          {:cont, :ok}
      end
    end)
  end

  defp validate_mcp_servers([]), do: :ok

  defp validate_mcp_servers(servers) do
    names = Enum.map(servers, &(&1["name"] || ""))

    cond do
      Enum.any?(names, &(&1 == "")) ->
        {:error, "mcp_servers_json", "each server must have a name"}

      length(names) != length(Enum.uniq(names)) ->
        {:error, "mcp_servers_json", "server names must be unique"}

      true ->
        :ok
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

  defp upload_error_to_string(:too_large), do: "File too large (max 5 MB)"
  defp upload_error_to_string(:not_accepted), do: "Unsupported file type"
  defp upload_error_to_string(:too_many_files), do: "Only one avatar allowed"
  defp upload_error_to_string(_), do: "Upload failed"

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
            <option value="">\u2014 none \u2014</option>
            <option :for={e <- @envs} value={e.id} selected={@form["environment_id"] == e.id}>{e.name}</option>
          </select>
        </div>

        <%!-- Avatar --%>
        <div class="space-y-3">
          <label class="block text-sm font-medium text-zinc-700">Avatar</label>

          <div :if={@agent.id && @agent.avatar_media_type && !@generated_avatar_preview}
               class="flex items-center gap-3">
            <img
              src={~p"/agents/#{@agent.id}/avatar"}
              class="w-14 h-14 rounded-xl object-cover border border-zinc-200"
              alt="Current avatar"
            />
            <button
              type="button"
              phx-click="remove_avatar"
              class="text-sm text-rose-600 hover:text-rose-800 underline underline-offset-2"
            >
              Remove
            </button>
          </div>

          <div :if={@generated_avatar_preview} class="flex items-center gap-3">
            <img
              src={@generated_avatar_preview}
              class="w-14 h-14 rounded-xl object-cover border border-zinc-200"
              alt="Generated avatar preview"
            />
            <div class="text-sm space-y-0.5">
              <p class="text-zinc-500">Will be saved when you submit.</p>
              <button
                type="button"
                phx-click="discard_generated_avatar"
                class="text-rose-600 hover:text-rose-800 underline underline-offset-2"
              >
                Discard
              </button>
            </div>
          </div>

          <div class="flex gap-0.5 rounded-lg border border-zinc-200 bg-zinc-50 p-0.5 w-fit text-sm">
            <button
              type="button"
              phx-click="switch_avatar_tab"
              phx-value-tab="upload"
              class={[
                "px-3 py-1 rounded-md transition-colors",
                @avatar_tab == :upload && "bg-white shadow-sm font-medium text-zinc-900",
                @avatar_tab != :upload && "text-zinc-500 hover:text-zinc-700"
              ]}
            >
              Upload
            </button>
            <button
              type="button"
              phx-click="switch_avatar_tab"
              phx-value-tab="generate"
              class={[
                "px-3 py-1 rounded-md transition-colors",
                @avatar_tab == :generate && "bg-white shadow-sm font-medium text-zinc-900",
                @avatar_tab != :generate && "text-zinc-500 hover:text-zinc-700"
              ]}
            >
              Generate with AI
            </button>
          </div>

          <div :if={@avatar_tab == :upload} class="space-y-2">
            <.live_file_input
              upload={@uploads.avatar}
              class="block text-sm text-zinc-700 file:mr-3 file:rounded file:border-0
                     file:bg-zinc-100 file:px-3 file:py-1.5 file:text-sm file:font-medium
                     file:cursor-pointer hover:file:bg-zinc-200"
            />
            <p class="text-xs text-zinc-500">JPEG, PNG, GIF, or WebP \u00b7 max 5 MB</p>

            <div :for={entry <- @uploads.avatar.entries} class="flex items-center gap-3">
              <.live_img_preview
                entry={entry}
                class="w-14 h-14 rounded-xl object-cover border border-zinc-200"
              />
              <div class="text-sm text-zinc-600">
                <p class="font-medium">{entry.client_name}</p>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="text-rose-600 hover:text-rose-800 underline underline-offset-2"
                >
                  Remove
                </button>
              </div>
              <p :for={err <- upload_errors(@uploads.avatar, entry)} class="text-rose-600 text-xs">
                {upload_error_to_string(err)}
              </p>
            </div>
          </div>

          <div :if={@avatar_tab == :generate} class="space-y-3">
            <div class="space-y-1.5">
              <p class="text-xs font-medium text-zinc-600">Base</p>
              <div class="flex gap-1.5">
                <button
                  :for={b <- AvatarGenerator.bases()}
                  type="button"
                  phx-click="set_avatar_base"
                  phx-value-base={b}
                  class={[
                    "px-3 py-1.5 rounded-md text-sm border transition-colors",
                    @avatar_base == b && "bg-zinc-900 text-white border-zinc-900",
                    @avatar_base != b && "bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50"
                  ]}
                >
                  {String.capitalize(b)}
                </button>
              </div>
            </div>

            <div class="space-y-1.5">
              <p class="text-xs font-medium text-zinc-600">Mood</p>
              <div class="flex gap-1.5">
                <button
                  :for={m <- AvatarGenerator.moods()}
                  type="button"
                  phx-click="set_avatar_mood"
                  phx-value-mood={m}
                  class={[
                    "px-3 py-1.5 rounded-md text-sm border transition-colors",
                    @avatar_mood == m && "bg-zinc-900 text-white border-zinc-900",
                    @avatar_mood != m && "bg-white text-zinc-600 border-zinc-300 hover:bg-zinc-50"
                  ]}
                >
                  {String.capitalize(m)}
                </button>
              </div>
            </div>

            <button
              type="button"
              phx-click="generate_avatar"
              disabled={@generating_avatar}
              class="flex items-center gap-2 rounded-md bg-zinc-900 px-4 py-2 text-sm font-medium
                     text-white hover:bg-zinc-700 disabled:opacity-60 disabled:cursor-not-allowed"
            >
              <%= if @generating_avatar do %>
                <svg class="animate-spin h-4 w-4" xmlns="http://www.w3.org/2000/svg" fill="none" viewBox="0 0 24 24">
                  <circle class="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" stroke-width="4"></circle>
                  <path class="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"></path>
                </svg>
                Generating\u2026
              <% else %>
                Generate
              <% end %>
            </button>

            <p :if={@avatar_error} class="text-rose-600 text-xs">{@avatar_error}</p>
          </div>
        </div>

        <%!-- Skills --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">Skills</label>

          <div :if={@skills == []} class="text-sm text-zinc-400 italic py-1">No skills configured.</div>

          <div
            :for={{skill, i} <- Enum.with_index(@skills)}
            class="border border-zinc-200 rounded-md p-3 bg-zinc-50 space-y-2"
          >
            <div class="flex items-center justify-between">
              <div class="flex gap-0.5 rounded border border-zinc-200 bg-white p-0.5 text-xs">
                <button
                  type="button"
                  phx-click="set_skill_type"
                  phx-value-index={i}
                  phx-value-type="github"
                  class={[
                    "px-2 py-0.5 rounded-sm transition-colors",
                    skill["type"] == "github" && "bg-zinc-900 text-white",
                    skill["type"] != "github" && "text-zinc-500 hover:text-zinc-700"
                  ]}
                >
                  GitHub
                </button>
                <button
                  type="button"
                  phx-click="set_skill_type"
                  phx-value-index={i}
                  phx-value-type="inline"
                  class={[
                    "px-2 py-0.5 rounded-sm transition-colors",
                    skill["type"] == "inline" && "bg-zinc-900 text-white",
                    skill["type"] != "inline" && "text-zinc-500 hover:text-zinc-700"
                  ]}
                >
                  Inline
                </button>
              </div>
              <button
                type="button"
                phx-click="remove_skill"
                phx-value-index={i}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium"
              >
                Remove
              </button>
            </div>

            <input type="hidden" name={"agent[skills][#{i}][type]"} value={skill["type"]} />

            <div :if={skill["type"] == "github"} class="grid grid-cols-2 gap-2">
              <.input
                id={"skill_#{i}_source"}
                name={"agent[skills][#{i}][source]"}
                label="Source (owner/repo)"
                value={skill["source"] || ""}
                placeholder="anthropics/skills"
              />
              <.input
                id={"skill_#{i}_name"}
                name={"agent[skills][#{i}][name]"}
                label="Name (optional)"
                value={skill["name"] || ""}
                placeholder="brainstorming"
              />
            </div>

            <div :if={skill["type"] == "inline"} class="space-y-2">
              <.input
                id={"skill_#{i}_inline_name"}
                name={"agent[skills][#{i}][name]"}
                label="Name"
                value={skill["name"] || ""}
                placeholder="my-skill"
              />
              <.input
                id={"skill_#{i}_content"}
                name={"agent[skills][#{i}][content]"}
                type="textarea"
                rows="8"
                label="Content (SKILL.md body)"
                value={skill["content"] || ""}
                placeholder="# My Skill&#10;&#10;..."
              />
            </div>
          </div>

          <button
            type="button"
            phx-click="add_skill"
            class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
          >
            + Add skill
          </button>
          <.error_msg field="skills_json" errors={@errors} />

          <div class="text-xs text-zinc-500 space-y-2 mt-1">
            <p>
              GitHub skills are fetched via
              <a href="https://skills.sh" target="_blank" class="underline">skills.sh</a>
              using the <code>source</code> (owner/repo) and optional skill <code>name</code>.
              Inline skills embed a full SKILL.md body directly.
              <.link navigate={~p"/help/skills"} class="underline">Skills help \u2192</.link>
            </p>
            <div class="rounded border border-blue-200 bg-blue-50 px-3 py-2 text-blue-900 leading-relaxed">
              <strong>Always included:</strong>
              the built-in <code>fountain</code> skill is automatically mounted in every
              conversation \u2014 no need to declare it. It gives the agent
              <code>$FOUNTAIN_TOKEN</code>, <code>$FOUNTAIN_BASE_URL</code>, and
              <code>$FOUNTAIN_CONVERSATION_ID</code> so it can spawn and coordinate sub-agents.
            </div>
          </div>
        </div>

        <%!-- MCP servers --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">MCP servers</label>

          <div :if={@mcp_servers == []} class="text-sm text-zinc-400 italic py-1">
            No MCP servers configured.
          </div>

          <div
            :for={{server, i} <- Enum.with_index(@mcp_servers)}
            class="border border-zinc-200 rounded-md p-3 bg-zinc-50 space-y-2"
          >
            <div class="flex items-center justify-between">
              <span class="text-xs font-semibold text-zinc-500 uppercase tracking-wide">Server {i + 1}</span>
              <button
                type="button"
                phx-click="remove_mcp_server"
                phx-value-index={i}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium"
              >
                Remove
              </button>
            </div>

            <.input
              id={"mcp_#{i}_name"}
              name={"agent[mcp_servers][#{i}][name]"}
              label="Server name"
              value={server["name"] || ""}
              placeholder="github"
            />
            <.input
              id={"mcp_#{i}_command"}
              name={"agent[mcp_servers][#{i}][command]"}
              label="Command"
              value={server["command"] || ""}
              placeholder="npx"
            />
            <.input
              id={"mcp_#{i}_args"}
              name={"agent[mcp_servers][#{i}][args]"}
              type="textarea"
              rows="2"
              label="Args (one per line)"
              value={server["args"] || ""}
              placeholder="-y&#10;@modelcontextprotocol/server-github"
            />

            <div class="space-y-1.5">
              <label class="block text-xs font-medium text-zinc-600">Env vars (optional)</label>

              <div class="space-y-1">
                <div
                  :for={{ev, j} <- Enum.with_index(server["env_vars"] || [])}
                  class="flex gap-2 items-center"
                >
                  <input
                    type="text"
                    name={"agent[mcp_servers][#{i}][env_vars][#{j}][key]"}
                    value={ev["key"] || ""}
                    placeholder="KEY"
                    class="w-32 rounded border border-zinc-300 px-2 py-1 text-xs font-mono"
                  />
                  <span class="text-zinc-400 text-xs select-none">=</span>
                  <input
                    type="text"
                    name={"agent[mcp_servers][#{i}][env_vars][#{j}][value]"}
                    value={ev["value"] || ""}
                    placeholder="value"
                    class="flex-1 rounded border border-zinc-300 px-2 py-1 text-xs"
                  />
                  <button
                    type="button"
                    phx-click="remove_mcp_env_var"
                    phx-value-server={i}
                    phx-value-index={j}
                    class="text-xs text-rose-400 hover:text-rose-600 font-medium shrink-0"
                  >
                    Remove
                  </button>
                </div>
              </div>

              <button
                type="button"
                phx-click="add_mcp_env_var"
                phx-value-server={i}
                class="text-xs font-medium text-indigo-600 hover:text-indigo-800"
              >
                + Add env var
              </button>
            </div>
          </div>

          <button
            type="button"
            phx-click="add_mcp_server"
            class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
          >
            + Add server
          </button>
          <.error_msg field="mcp_servers_json" errors={@errors} />
        </div>

        <div class="flex gap-2">
          <.btn type="submit" phx-disable-with="Saving\u2026">Save</.btn>
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
