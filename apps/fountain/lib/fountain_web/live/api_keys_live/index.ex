defmodule FountainWeb.ApiKeysLive.Index do
  use FountainWeb, :live_view

  alias Fountain.Accounts

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    keys = Accounts.list_api_keys(user.id)

    {:ok,
     socket
     |> assign(:page_title, "API keys")
     |> assign(:user_id, user.id)
     |> assign(:keys, keys)
     |> assign(:new_key, nil)}
  end

  @impl true
  def handle_event("create_key", %{"label" => label}, socket) do
    case Accounts.create_api_key(socket.assigns.user_id, label) do
      {:ok, {key, raw_token}} ->
        {:noreply,
         socket
         |> assign(:keys, Accounts.list_api_keys(socket.assigns.user_id))
         |> assign(:new_key, %{key: key, raw_token: raw_token})
         |> put_flash(:info, "API key created — copy it now, it won't be shown again")}

      {:error, _cs} ->
        {:noreply, put_flash(socket, :error, "Failed to create API key")}
    end
  end

  def handle_event("dismiss_new_key", _params, socket) do
    {:noreply, assign(socket, :new_key, nil)}
  end

  def handle_event("revoke", %{"id" => id}, socket) do
    case Accounts.revoke_api_key(socket.assigns.user_id, id) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:keys, Accounts.list_api_keys(socket.assigns.user_id))
         |> put_flash(:info, "Key revoked")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Key not found")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6 max-w-2xl">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-semibold">API keys</h1>
          <p class="text-sm text-zinc-500 mt-1">
            Use these to authenticate requests to the Fountain API.
            Keys are shown once — copy them immediately.
          </p>
        </div>
      </div>

      <div :if={@new_key} class="rounded-lg bg-green-50 border border-green-200 p-4 space-y-3">
        <p class="text-sm font-medium text-green-800">
          New API key created. Copy it now — it won't be shown again.
        </p>
        <div class="flex items-center gap-2">
          <code
            id="new-api-key"
            class="flex-1 bg-white rounded border border-green-300 px-3 py-2 text-sm font-mono text-zinc-900 break-all">
            {@new_key.raw_token}
          </code>
          <button
            phx-hook="CopyToClipboard"
            id="copy-api-key"
            data-target="new-api-key"
            class="shrink-0 rounded border border-green-300 bg-white px-3 py-2 text-xs text-green-700 hover:bg-green-50">
            Copy
          </button>
        </div>
        <button phx-click="dismiss_new_key" class="text-xs text-green-600 hover:text-green-800 underline">
          I've copied it, dismiss
        </button>
      </div>

      <form phx-submit="create_key" class="flex gap-2">
        <input type="text" name="label" placeholder="Key label (e.g. ci-deploy)"
          required minlength="1"
          class="flex-1 rounded-md border border-zinc-300 px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-zinc-900"/>
        <button type="submit"
          class="rounded-md bg-zinc-900 text-white px-4 py-2 text-sm font-medium hover:bg-zinc-700">
          Create key
        </button>
      </form>

      <div :if={@keys == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500">
        No API keys yet.
      </div>

      <table :if={@keys != []} class="w-full text-sm bg-white rounded shadow border border-zinc-200">
        <thead class="text-left text-zinc-500 border-b border-zinc-200">
          <tr>
            <th class="px-4 py-2">Label</th>
            <th class="px-4 py-2">Prefix</th>
            <th class="px-4 py-2">Created</th>
            <th class="px-4 py-2">Last used</th>
            <th class="px-4 py-2"></th>
          </tr>
        </thead>
        <tbody>
          <tr :for={k <- @keys} class="border-b border-zinc-100 last:border-0 hover:bg-zinc-50">
            <td class="px-4 py-2 font-medium">{k.name}</td>
            <td class="px-4 py-2 font-mono text-zinc-500 text-xs">{k.key_prefix}···</td>
            <td class="px-4 py-2 text-zinc-500 text-xs">{format_date(k.inserted_at)}</td>
            <td class="px-4 py-2 text-zinc-500 text-xs">
              {if k.last_used_at, do: format_date(k.last_used_at), else: "—"}
            </td>
            <td class="px-4 py-2 text-right">
              <button phx-click="revoke" phx-value-id={k.id}
                data-confirm="Revoke this key? Any integrations using it will stop working."
                class="text-xs text-red-600 hover:text-red-800 underline">
                Revoke
              </button>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp format_date(nil), do: ""
  defp format_date(dt), do: Calendar.strftime(dt, "%Y-%m-%d")
end
