defmodule FountainWeb.VaultsLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Vaults

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id

    {:ok,
     socket
     |> assign(:page_title, "Vaults")
     |> assign(:user_id, user_id)
     |> assign(:filter_search, "")
     |> assign(:vaults, load_vaults(user_id, ""))}
  end

  @impl true
  def handle_event("search", %{"search" => search}, socket) do
    search = String.trim(search)

    {:noreply,
     socket
     |> assign(:filter_search, search)
     |> assign(:vaults, load_vaults(socket.assigns.user_id, search))}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    vault = Vaults.get_vault!(id, socket.assigns.user_id)
    {:ok, _} = Vaults.delete_vault(vault)

    {:noreply,
     socket
     |> assign(:vaults, load_vaults(socket.assigns.user_id, socket.assigns.filter_search))
     |> put_flash(:info, "Deleted #{vault.name}")}
  end

  defp load_vaults(user_id, search) do
    vaults = Vaults.list_vaults_with_counts(user_id)

    if search == "" do
      vaults
    else
      term = String.downcase(search)
      Enum.filter(vaults, fn v -> String.contains?(String.downcase(v.name), term) end)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Vaults</h1>
        <.link navigate={~p"/vaults/new"}><.btn>+ New vault</.btn></.link>
      </div>

      <p class="text-sm max-w-2xl" style="color:#6b7280;">
        A <strong style="color:#9ca3af;">vault</strong> is a bag of env-var overrides — your credentials, a teammate's, or a virtual identity.
        Pick one when starting a conversation and its values override the environment's baseline secrets at sprite spawn.
      </p>

      <%!-- Search bar --%>
      <form phx-change="search" phx-submit="search">
        <input
          type="text"
          name="search"
          value={@filter_search}
          phx-debounce="200"
          placeholder="Search vaults…"
          class="w-64 rounded border px-3 py-1.5 text-sm focus:outline-none"
          style="background:#111;border-color:#2a2a2a;color:#e5e7eb;"
        />
      </form>

      <%!-- Empty state — no vaults at all --%>
      <div
        :if={@vaults == [] and @filter_search == ""}
        class="rounded-lg p-10 text-center"
        style="background:#0a0a0a;border:1px dashed #2a2a2a;"
      >
        <p class="text-sm" style="color:#6b7280;">No vaults yet.</p>
        <p class="text-xs mt-1" style="color:#374151;">Create a vault to store a set of credential overrides you can apply per conversation.</p>
      </div>

      <%!-- Empty state — search returned nothing --%>
      <div
        :if={@vaults == [] and @filter_search != ""}
        class="rounded-lg p-8 text-center"
        style="background:#0a0a0a;border:1px dashed #2a2a2a;"
      >
        <p class="text-sm" style="color:#6b7280;">No vaults match <span class="font-mono" style="color:#9ca3af;">"{@filter_search}"</span>.</p>
      </div>

      <%!-- Table --%>
      <table
        :if={@vaults != []}
        class="w-full text-sm rounded-lg overflow-hidden"
        style="background:#0a0a0a;border:1px solid #1a1a1a;"
      >
        <thead style="border-bottom:1px solid #222;">
          <tr>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Name</th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Description</th>
            <th class="px-4 py-3 text-left text-xs font-semibold uppercase tracking-wide" style="color:#4b5563;">Secrets</th>
            <th class="px-4 py-3"></th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={v <- @vaults}
            class="hover:bg-[#0d1117] transition-colors duration-150"
            style="border-bottom:1px solid #161616;"
          >
            <td class="px-4 py-3 font-medium" style="color:#e5e7eb;">{v.name}</td>
            <td class="px-4 py-3 max-w-md">
              <span
                :if={v.description != ""}
                class="text-xs block truncate"
                style="color:#4b5563;"
                title={v.description}
              >{v.description}</span>
              <span :if={v.description == ""} style="color:#374151;">—</span>
            </td>
            <td class="px-4 py-3">
              <span
                class="inline-flex items-center gap-1 px-2 py-0.5 rounded-full text-xs font-medium"
                style={secrets_badge_style(v.secret_count)}
                title={"#{v.secret_count} secrets"}
              >🔑 {v.secret_count}</span>
            </td>
            <td class="px-4 py-3 text-right">
              <div class="inline-flex gap-1">
                <.link navigate={~p"/vaults/#{v.id}/edit"}>
                  <button
                    class="px-2 py-1 rounded text-xs cursor-pointer"
                    style="background:#1a1a1a;border:1px solid #2a2a2a;color:#9ca3af;"
                  >Edit</button>
                </.link>
                <button
                  class="px-2 py-1 rounded text-xs cursor-pointer"
                  style="background:#1a0d0d;border:1px solid #3a1a1a;color:#f87171;"
                  phx-click="delete"
                  phx-value-id={v.id}
                  data-confirm="Delete vault?"
                >Delete</button>
              </div>
            </td>
          </tr>
        </tbody>
      </table>
    </div>
    """
  end

  defp secrets_badge_style(0),
    do: "background:#111;color:#374151;border:1px solid #1f1f1f;"

  defp secrets_badge_style(_),
    do: "background:#1a1200;color:#fbbf24;border:1px solid #3a2a00;"
end
