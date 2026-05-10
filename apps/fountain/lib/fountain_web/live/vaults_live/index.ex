defmodule FountainWeb.VaultsLive.Index do
  use FountainWeb, :live_view

  alias Fountain.Vaults

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Vaults")
     |> assign(:vaults, list_vaults())}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    vault = Vaults.get_vault!(id)
    {:ok, _} = Vaults.delete_vault(vault)

    {:noreply,
     socket
     |> assign(:vaults, list_vaults())
     |> put_flash(:info, "Deleted #{vault.name}")}
  end

  defp list_vaults do
    Vaults.list_vaults()
    |> Enum.map(fn vault ->
      Map.put(vault, :secret_count, length(Vaults.list_secrets(vault)))
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Vaults</h1>
        <.link navigate={~p"/vaults/new"}><.btn>+ New vault</.btn></.link>
      </div>

      <p class="text-sm text-zinc-500 max-w-2xl">
        A <strong>vault</strong> is a bag of env-var overrides — your credentials, a teammate's, or a virtual identity.
        Pick one when starting a conversation and its values override the environment's baseline secrets at sprite spawn.
      </p>

      <div :if={@vaults == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500">
        No vaults yet.
      </div>

      <table :if={@vaults != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
        <thead class="text-left text-zinc-500 border-b border-zinc-200">
          <tr>
            <th class="px-4 py-2">Name</th>
            <th class="px-4 py-2">Description</th>
            <th class="px-4 py-2">Secrets</th>
            <th class="px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={v <- @vaults} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
            <td class="px-4 py-2 font-medium">{v.name}</td>
            <td class="px-4 py-2 text-zinc-600 truncate max-w-md">
              {if v.description == "", do: "—", else: v.description}
            </td>
            <td class="px-4 py-2 text-zinc-600">{v.secret_count}</td>
            <td class="px-4 py-2 text-right space-x-2">
              <.link navigate={~p"/vaults/#{v.id}/edit"}><.btn_secondary>Edit</.btn_secondary></.link>
              <.btn_danger phx-click="delete" phx-value-id={v.id} data-confirm="Delete vault?">Delete</.btn_danger>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end
end
