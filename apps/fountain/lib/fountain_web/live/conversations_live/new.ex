defmodule FountainWeb.ConversationsLive.New do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Agents, Conversations, Vaults}

  @impl true
  def mount(_params, _session, socket) do
    user_id = socket.assigns.current_user.id
    agents = Agents.list_agents(user_id, [])
    vaults = Vaults.list_vaults(user_id)

    {:ok,
     socket
     |> assign(:page_title, "New conversation")
     |> assign(:user_id, user_id)
     |> assign(:agents, agents)
     |> assign(:vaults, vaults)
     |> assign(:form, %{
       "agent_id" => first_agent_id(agents),
       "vault_id" => "",
       "prompt" => ""
     })}
  end

  @impl true
  def handle_event("validate", %{"conv" => params}, socket) do
    {:noreply, assign(socket, :form, params)}
  end

  def handle_event("submit", %{"conv" => params}, socket) do
    params = if params["vault_id"] == "", do: Map.delete(params, "vault_id"), else: params
    params = Map.put(params, "source", "ui")
    params = Map.put(params, "user_id", socket.assigns.user_id)

    case Conversations.start_conversation(params) do
      {:ok, conv} ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation started")
         |> push_navigate(to: ~p"/conversations/#{conv.id}")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Agent not found")}

      {:error, :vault_not_found} ->
        {:noreply, put_flash(socket, :error, "Vault not found")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(reason)}")}
    end
  end

  defp first_agent_id([]), do: nil
  defp first_agent_id([a | _]), do: a.id

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl space-y-6">
      <h1 class="text-2xl font-semibold">New conversation</h1>

      <div :if={@agents == []} class="rounded border border-dashed border-zinc-300 p-8 text-center text-zinc-500 space-y-2">
        <div>No agents defined yet.</div>
        <.link navigate={~p"/agents/new"} class="text-zinc-900 underline">Create one</.link>
      </div>

      <form :if={@agents != []} phx-change="validate" phx-submit="submit" class="space-y-4 bg-white rounded shadow p-6 border border-zinc-200">
        <div class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Agent</label>
          <select name="conv[agent_id]" class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
            <option :for={a <- @agents} value={a.id} selected={@form["agent_id"] == a.id}>
              {a.name} ({a.runtime} &middot; {a.model})
            </option>
          </select>
        </div>
        <div :if={@vaults != []} class="space-y-1">
          <label class="block text-sm font-medium text-zinc-700">Vault <span class="text-zinc-400 font-normal">(optional)</span></label>
          <select name="conv[vault_id]" class="w-full rounded-md border border-zinc-300 bg-white px-3 py-2 text-sm">
            <option value="" selected={@form["vault_id"] in [nil, ""]}>&#8212; none &#8212;</option>
            <option :for={v <- @vaults} value={v.id} selected={@form["vault_id"] == v.id}>
              {v.name}
            </option>
          </select>
          <p class="text-xs text-zinc-500">
            Layered on top of the environment's secrets at sprite spawn. Vault values win on key collision.
          </p>
        </div>
        <.input id="prompt" name="conv[prompt]" type="textarea" label="First prompt"
          value={@form["prompt"]} rows="6" placeholder="What should the agent do?" autofocus required
          phx-hook="SubmitOnCmdEnter"/>
        <div class="flex gap-2 items-center">
          <.btn type="submit" phx-disable-with="Starting&hellip;">Start</.btn>
          <.link navigate={~p"/"}><.btn_secondary>Cancel</.btn_secondary></.link>
          <span class="text-xs text-zinc-400 ml-1">or <kbd class="px-1 py-0.5 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono">&#8984;</kbd> <kbd class="px-1 py-0.5 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono">Enter</kbd></span>
        </div>
      </form>
    </div>
    """
  end
end
