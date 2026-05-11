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
     |> assign(:envs, list_envs(user_id))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    env = Environments.get_environment!(id, socket.assigns.user_id)
    {:ok, _} = Environments.delete_environment(env)

    {:noreply,
     socket
     |> assign(:envs, list_envs(socket.assigns.user_id))
     |> put_flash(:info, "Deleted #{env.name}")}
  end

  defp list_envs(user_id) do
    Environments.list_environments(user_id)
    |> Enum.map(fn env ->
      Map.put(env, :secret_count, length(Environments.list_secrets(env)))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Environments</h1>
        <.link navigate={~p"/environments/new"}><.btn>+ New environment</.btn></.link>
      </div>

      <div :if={@envs == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500">
        No environments yet.
      </div>

      <table :if={@envs != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
        <thead class="text-left text-zinc-500 border-b border-zinc-200">
          <tr>
            <th class="px-4 py-2">Name</th>
            <th class="px-4 py-2">Setup</th>
            <th class="px-4 py-2">Secrets</th>
            <th class="px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={e <- @envs} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
            <td class="px-4 py-2 font-medium">{e.name}</td>
            <td class="px-4 py-2 text-zinc-600 font-mono text-xs truncate max-w-xs">
              {if e.setup_script == "", do: "—", else: e.setup_script}
            </td>
            <td class="px-4 py-2 text-zinc-600">{e.secret_count}</td>
            <td class="px-4 py-2 text-right space-x-2">
              <.link navigate={~p"/environments/#{e.id}/edit"}><.btn_secondary>Edit</.btn_secondary></.link>
              <.btn_danger phx-click="delete" phx-value-id={e.id} data-confirm="Delete environment?">Delete</.btn_danger>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
