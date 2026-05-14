defmodule FountainWeb.EnvironmentsLive.Form do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Crypto, Environments}
  alias Fountain.Environments.Environment

  @supported_managers ~w(apt npm pip cargo gem go)

  @impl true
  def mount(params, _session, socket) do
    user_id = socket.assigns.current_user.id
    {env, action} = load(params, user_id)
    {:ok, dek} = Crypto.load_tenant_key(user_id)

    {:ok,
     socket
     |> assign(:page_title, page_title(action))
     |> assign(:user_id, user_id)
     |> assign(:tenant_key, dek)
     |> assign(:action, action)
     |> assign(:env, env)
     |> assign(:form, env_to_form(env))
     |> assign(:errors, %{})
     |> assign(:secrets, secrets_for(env))
     |> assign(:new_secret, %{"key" => "", "value" => ""})
     |> assign(:repositories, env.repositories || [])
     |> assign(:env_vars, env_to_env_var_list(env.env_vars || %{}))
     |> assign(:packages, env_to_packages_strings(env.packages || %{}))
     |> assign(:available_managers, available_managers(env.packages || %{}))}
  end

  defp load(%{"id" => id}, user_id), do: {Environments.get_environment!(id, user_id), :edit}
  defp load(_, _user_id), do: {%Environment{}, :new}

  defp page_title(:new), do: "New environment"
  defp page_title(:edit), do: "Edit environment"

  defp env_to_form(%Environment{} = e) do
    %{
      "name" => e.name || "",
      "setup_script" => e.setup_script || "",
      "networking_type" => e.networking_type || "unrestricted",
      "networking_config_json" => Jason.encode!(e.networking_config || %{}, pretty: true)
    }
  end

  defp env_to_env_var_list(env_vars) do
    Enum.map(env_vars, fn {k, v} -> %{"key" => k, "value" => v} end)
  end

  defp env_to_packages_strings(packages) do
    Map.new(packages, fn {manager, pkgs} ->
      {manager, Enum.join(pkgs, "\n")}
    end)
  end

  defp available_managers(packages) do
    @supported_managers -- Map.keys(packages)
  end

  defp secrets_for(%Environment{id: nil}), do: []
  defp secrets_for(env), do: Environments.list_secrets(env)

  @impl true
  def handle_event("validate", %{"env" => params}, socket) do
    repos = extract_repos_from_params(params)
    env_vars = extract_env_vars_from_params(params)
    packages = extract_packages_from_params(params, socket.assigns.packages)

    {:noreply,
     socket
     |> assign(:form, params)
     |> assign(:repositories, repos)
     |> assign(:env_vars, env_vars)
     |> assign(:packages, packages)}
  end

  def handle_event("add_env_var", _, socket) do
    env_vars = socket.assigns.env_vars ++ [%{"key" => "", "value" => ""}]
    {:noreply, assign(socket, :env_vars, env_vars)}
  end

  def handle_event("remove_env_var", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    env_vars = List.delete_at(socket.assigns.env_vars, index)
    {:noreply, assign(socket, :env_vars, env_vars)}
  end

  def handle_event("add_package_manager", %{"manager" => manager}, socket) do
    packages = Map.put(socket.assigns.packages, manager, "")
    available = socket.assigns.available_managers -- [manager]
    {:noreply, socket |> assign(:packages, packages) |> assign(:available_managers, available)}
  end

  def handle_event("remove_package_manager", %{"manager" => manager}, socket) do
    packages = Map.delete(socket.assigns.packages, manager)

    available =
      (socket.assigns.available_managers ++ [manager])
      |> Enum.sort_by(&Enum.find_index(@supported_managers, fn m -> m == &1 end))

    {:noreply, socket |> assign(:packages, packages) |> assign(:available_managers, available)}
  end

  def handle_event("add_repo", _, socket) do
    repos =
      socket.assigns.repositories ++
        [%{"url" => "", "mount_path" => "/workspace/", "secret_key" => "", "ref" => ""}]

    {:noreply, assign(socket, :repositories, repos)}
  end

  def handle_event("remove_repo", %{"index" => index_str}, socket) do
    index = String.to_integer(index_str)
    repos = List.delete_at(socket.assigns.repositories, index)
    {:noreply, assign(socket, :repositories, repos)}
  end

  def handle_event("submit", %{"env" => params}, socket) do
    repos = extract_repos_from_params(params)
    env_vars_list = extract_env_vars_from_params(params)
    packages_strings = extract_packages_from_params(params, socket.assigns.packages)

    with {:ok, networking} <-
           parse_json_object(params["networking_config_json"], "networking_config_json"),
         :ok <- validate_env_vars(env_vars_list),
         :ok <- validate_repos(repos) do
      env_vars_map = Map.new(env_vars_list, fn %{"key" => k, "value" => v} -> {k, v} end)

      packages_map =
        packages_strings
        |> Map.new(fn {manager, pkg_str} ->
          pkgs =
            pkg_str
            |> String.split("\n")
            |> Enum.map(&String.trim/1)
            |> Enum.reject(&(&1 == ""))

          {manager, pkgs}
        end)
        |> Map.reject(fn {_, pkgs} -> pkgs == [] end)

      attrs =
        params
        |> Map.put("env_vars", env_vars_map)
        |> Map.put("packages", packages_map)
        |> Map.put("networking_config", networking)
        |> Map.put("repositories", repos)
        |> Map.drop(["networking_config_json"])

      save(socket, attrs)
    else
      {:error, field, msg} ->
        {:noreply, assign(socket, :errors, %{field => msg})}
    end
  end

  def handle_event("validate_secret", %{"secret" => params}, socket) do
    {:noreply, assign(socket, :new_secret, params)}
  end

  def handle_event("add_secret", %{"secret" => %{"key" => k, "value" => v}}, socket)
      when k != "" and v != "" do
    case Environments.upsert_secret(
           socket.assigns.env,
           %{"key" => k, "value" => v},
           socket.assigns.tenant_key
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:secrets, secrets_for(socket.assigns.env))
         |> assign(:new_secret, %{"key" => "", "value" => ""})
         |> put_flash(:info, "Secret saved")}

      {:error, cs} ->
        {:noreply, put_flash(socket, :error, secret_error(cs))}
    end
  end

  def handle_event("add_secret", _, socket), do: {:noreply, socket}

  def handle_event("delete_secret", %{"id" => id}, socket) do
    secret = Enum.find(socket.assigns.secrets, &(&1.id == id))

    if secret do
      Environments.delete_secret(secret)

      {:noreply,
       socket
       |> assign(:secrets, secrets_for(socket.assigns.env))
       |> put_flash(:info, "Deleted secret #{secret.key}")}
    else
      {:noreply, socket}
    end
  end

  defp save(%{assigns: %{action: :new}} = socket, attrs) do
    attrs = Map.put(attrs, "user_id", socket.assigns.user_id)

    case Environments.create_environment(attrs) do
      {:ok, env} ->
        {:noreply,
         socket
         |> put_flash(:info, "Environment created")
         |> push_navigate(to: ~p"/environments/#{env.id}/edit")}

      {:error, cs} ->
        {:noreply, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp save(%{assigns: %{action: :edit, env: env}} = socket, attrs) do
    case Environments.update_environment(env, attrs) do
      {:ok, _env} ->
        {:noreply,
         socket
         |> put_flash(:info, "Environment updated")
         |> push_navigate(to: ~p"/environments")}

      {:error, cs} ->
        {:noreply, assign(socket, :errors, changeset_errors(cs))}
    end
  end

  defp extract_env_vars_from_params(params) do
    case params["env_vars"] do
      nil ->
        []

      vars_map when is_map(vars_map) ->
        vars_map
        |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
        |> Enum.map(fn {_, r} -> r end)

      _ ->
        []
    end
  end

  defp extract_packages_from_params(params, current_packages) do
    case params["packages"] do
      pkg_map when is_map(pkg_map) -> pkg_map
      _ -> current_packages
    end
  end

  defp extract_repos_from_params(params) do
    case params["repositories"] do
      nil ->
        []

      repos_map when is_map(repos_map) ->
        repos_map
        |> Enum.sort_by(fn {k, _} -> String.to_integer(k) end)
        |> Enum.map(fn {_, r} -> r end)

      _ ->
        []
    end
  end

  defp validate_env_vars([]), do: :ok

  defp validate_env_vars(env_vars) do
    keys = Enum.map(env_vars, &(&1["key"] || ""))

    cond do
      Enum.any?(keys, &(&1 == "")) ->
        {:error, "env_vars", "each variable must have a key"}

      length(keys) != length(Enum.uniq(keys)) ->
        {:error, "env_vars", "variable keys must be unique"}

      true ->
        :ok
    end
  end

  defp validate_repos([]), do: :ok

  defp validate_repos(repos) do
    Enum.reduce_while(repos, :ok, fn repo, _acc ->
      url = repo["url"] || ""
      mount = repo["mount_path"] || ""

      cond do
        url == "" ->
          {:halt, {:error, "repositories", "each repo must have a url"}}

        not String.starts_with?(url, "https://") ->
          {:halt, {:error, "repositories", "each repo url must start with https://"}}

        mount == "" ->
          {:halt, {:error, "repositories", "each repo must have a mount_path"}}

        not String.starts_with?(mount, "/") ->
          {:halt, {:error, "repositories", "each repo mount_path must be an absolute path"}}

        true ->
          {:cont, :ok}
      end
    end)
  end

  defp parse_json_object(nil, _field), do: {:ok, %{}}
  defp parse_json_object("", _field), do: {:ok, %{}}

  defp parse_json_object(json, field) do
    case Jason.decode(json) do
      {:ok, m} when is_map(m) -> {:ok, m}
      _ -> {:error, field, "must be a JSON object"}
    end
  end

  defp changeset_errors(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {k, v}, acc -> String.replace(acc, "%{#{k}}", to_string(v)) end)
    end)
    |> Map.new(fn {k, [first | _]} -> {to_string(k), first} end)
  end

  defp secret_error(cs) do
    cs
    |> Ecto.Changeset.traverse_errors(fn {msg, _} -> msg end)
    |> Enum.flat_map(fn {k, msgs} -> Enum.map(msgs, &"#{k}: #{&1}") end)
    |> Enum.join("; ")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-3xl space-y-6">
      <h1 class="text-2xl font-semibold">{page_title(@action)}</h1>

      <form phx-change="validate" phx-submit="submit" class="space-y-4 bg-white rounded shadow p-6 border border-zinc-200">
        <.input id="env_name" name="env[name]" label="Name" value={@form["name"]} autofocus required />
        <.error_msg field="name" errors={@errors}/>

        <%!-- Packages --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">Packages</label>

          <div :if={map_size(@packages) == 0} class="text-sm text-zinc-400 italic py-1">
            No packages configured.
          </div>

          <div
            :for={{manager, pkg_str} <- Enum.sort(@packages)}
            class="border border-zinc-200 rounded-md p-3 bg-zinc-50 space-y-1"
          >
            <div class="flex items-center justify-between">
              <span class="text-sm font-mono font-semibold text-zinc-700">{manager}</span>
              <button
                type="button"
                phx-click="remove_package_manager"
                phx-value-manager={manager}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium"
              >
                Remove
              </button>
            </div>
            <textarea
              id={"pkg_#{manager}"}
              name={"env[packages][#{manager}]"}
              rows="3"
              placeholder="one package per line"
              class="w-full rounded border border-zinc-300 px-2 py-1.5 text-sm font-mono resize-y"
            >{pkg_str}</textarea>
          </div>

          <div :if={@available_managers != []} class="flex gap-1.5 flex-wrap">
            <button
              :for={m <- @available_managers}
              type="button"
              phx-click="add_package_manager"
              phx-value-manager={m}
              class="text-xs border border-dashed border-zinc-300 rounded px-2 py-1 text-zinc-500 hover:border-indigo-400 hover:text-indigo-600 transition-colors"
            >
              + {m}
            </button>
          </div>
          <.error_msg field="packages" errors={@errors} />
        </div>

        <.input id="setup_script" name="env[setup_script]" type="textarea" rows="6"
          label="Setup script (runs after packages, before agent turns)" value={@form["setup_script"]}
          placeholder="curl -LsSf https://astral.sh/uv/install.sh | sh"/>

        <%!-- Env vars --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">
            Env vars <span class="font-normal text-zinc-400">(non-secret)</span>
          </label>

          <div :if={@env_vars == []} class="text-sm text-zinc-400 italic py-1">
            No variables configured.
          </div>

          <div class="space-y-1.5">
            <div :for={{ev, i} <- Enum.with_index(@env_vars)} class="flex gap-2 items-center">
              <input
                id={"ev_#{i}_key"}
                type="text"
                name={"env[env_vars][#{i}][key]"}
                value={ev["key"] || ""}
                placeholder="KEY"
                class="w-36 rounded border border-zinc-300 px-2 py-1.5 text-sm font-mono"
              />
              <span class="text-zinc-400 text-sm select-none">=</span>
              <input
                id={"ev_#{i}_value"}
                type="text"
                name={"env[env_vars][#{i}][value]"}
                value={ev["value"] || ""}
                placeholder="value"
                class="flex-1 rounded border border-zinc-300 px-2 py-1.5 text-sm"
              />
              <button
                type="button"
                phx-click="remove_env_var"
                phx-value-index={i}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium shrink-0"
              >
                Remove
              </button>
            </div>
          </div>

          <button
            type="button"
            phx-click="add_env_var"
            class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
          >
            + Add variable
          </button>
          <.error_msg field="env_vars" errors={@errors} />
        </div>

        <%!-- Repositories --%>
        <div class="space-y-2">
          <label class="block text-sm font-medium text-zinc-700">Repositories</label>

          <div :if={@repositories == []} class="text-sm text-zinc-400 italic py-1">
            No repositories configured.
          </div>

          <div
            :for={{repo, i} <- Enum.with_index(@repositories)}
            class="border border-zinc-200 rounded-md p-3 space-y-2 bg-zinc-50"
          >
            <div class="flex items-center justify-between">
              <span class="text-xs font-semibold text-zinc-500 uppercase tracking-wide">Repo {i + 1}</span>
              <button
                type="button"
                phx-click="remove_repo"
                phx-value-index={i}
                class="text-xs text-rose-500 hover:text-rose-700 font-medium"
              >
                Remove
              </button>
            </div>
            <.input
              id={"repo_#{i}_url"}
              name={"env[repositories][#{i}][url]"}
              label="URL"
              value={repo["url"] || ""}
              placeholder="https://github.com/owner/repo"
            />
            <.input
              id={"repo_#{i}_mount_path"}
              name={"env[repositories][#{i}][mount_path]"}
              label="Mount path"
              value={repo["mount_path"] || ""}
              placeholder="/workspace/repo"
            />
            <div class="grid grid-cols-2 gap-2">
              <.input
                id={"repo_#{i}_secret_key"}
                name={"env[repositories][#{i}][secret_key]"}
                label="Secret key (optional)"
                value={repo["secret_key"] || ""}
                placeholder="GITHUB_TOKEN"
              />
              <.input
                id={"repo_#{i}_ref"}
                name={"env[repositories][#{i}][ref]"}
                label="Ref / branch (optional)"
                value={repo["ref"] || ""}
                placeholder="main"
              />
            </div>
          </div>

          <button
            type="button"
            phx-click="add_repo"
            class="text-sm font-medium text-indigo-600 hover:text-indigo-800"
          >
            + Add repository
          </button>
          <.error_msg field="repositories" errors={@errors} />
          <p class="text-xs text-zinc-500 mt-1">
            Repos are cloned into the sprite before your setup script runs.
            Set <code>mount_path</code> to where the repo should appear — use
            <code>/workspace/repo-name</code> as the convention (cloned repos live under
            <code>/workspace/</code> in the sprite). Use <code>secret_key</code> to name
            an env secret whose value is passed as <code>x-access-token</code> for
            cloning private repos.
          </p>
        </div>

        <div class="grid grid-cols-2 gap-3">
          <div class="space-y-1">
            <label class="block text-sm font-medium text-zinc-700">Networking</label>
            <select name="env[networking_type]" class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
              <option :for={t <- ~w(unrestricted limited)} value={t} selected={@form["networking_type"] == t}>{t}</option>
            </select>
          </div>
          <.input id="networking_config_json" name="env[networking_config_json]" type="textarea" rows="2"
            label="Networking config (JSON, used when limited)" value={@form["networking_config_json"]}
            placeholder='{"allowed_hosts": ["github.com", "api.anthropic.com"]}'/>
        </div>
        <.error_msg field="networking_config_json" errors={@errors}/>

        <div class="flex gap-2">
          <.btn type="submit" phx-disable-with="Saving…">Save</.btn>
          <.link navigate={~p"/environments"}><.btn_secondary>Cancel</.btn_secondary></.link>
        </div>
      </form>

      <section :if={@action == :edit} class="bg-white rounded shadow p-6 border border-zinc-200 space-y-4">
        <h2 class="text-lg font-semibold">Secrets</h2>
        <p class="text-sm text-zinc-500">
          Encrypted at rest with AES-256-GCM. Values are written into the sprite environment at
          provision time and never returned over the API.
        </p>

        <div :if={@secrets == []} class="text-sm text-zinc-500">No secrets yet.</div>

        <table :if={@secrets != []} class="w-full text-sm">
          <tbody>
            <tr :for={s <- @secrets} class="border-b border-zinc-100 last:border-0">
              <td class="py-2 font-mono">{s.key}</td>
              <td class="py-2 text-zinc-400 font-mono text-xs">&bull;&bull;&bull;&bull;&bull;&bull;&bull;</td>
              <td class="py-2 text-right">
                <.btn_danger phx-click="delete_secret" phx-value-id={s.id} data-confirm="Delete?">Delete</.btn_danger>
              </td>
            </tr>
          </tbody>
        </table>

        <form phx-change="validate_secret" phx-submit="add_secret" class="flex flex-col sm:flex-row gap-2">
          <input type="text" name="secret[key]" value={@new_secret["key"]} placeholder="KEY"
            pattern="[A-Z][A-Z0-9_]*"
            class="flex-1 rounded border border-zinc-300 px-3 py-2 text-sm font-mono"/>
          <input type="password" name="secret[value]" value={@new_secret["value"]} placeholder="value"
            class="flex-[2] rounded border border-zinc-300 px-3 py-2 text-sm font-mono"/>
          <.btn type="submit">Add secret</.btn>
        </form>
      </section>
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
