defmodule FountainWeb.ConversationsLive.Index do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.{Accounts, Agents, Conversations}

  @poll_interval 2_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :tick, @poll_interval)

    user = socket.assigns.current_user

    {:ok,
     socket
     |> assign(:page_title, "Conversations")
     |> assign(:sort_by, :inserted_at)
     |> assign(:sort_dir, :desc)
     |> assign(:roots_only, user.conversations_roots_only)
     |> load_data()}
  end

  @impl true
  def handle_info(:tick, socket) do
    Process.send_after(self(), :tick, @poll_interval)
    {:noreply, load_data(socket)}
  end

  @impl true
  def handle_event("terminate", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Not found")}

      _ ->
        case Fountain.Conversations.ConversationServer.terminate(id) do
          :ok -> {:noreply, socket |> put_flash(:info, "Terminated") |> load_data()}
          _ -> {:noreply, put_flash(socket, :error, "Not running")}
        end
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    user = socket.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Not found")}

      conv ->
        {:ok, _} = Conversations.delete_conversation(conv)
        {:noreply, socket |> put_flash(:info, "Deleted") |> load_data()}
    end
  end

  def handle_event("sort", %{"by" => field_str}, socket) do
    field = parse_sort_field(field_str)

    {sort_by, sort_dir} =
      if socket.assigns.sort_by == field do
        {field, toggle_dir(socket.assigns.sort_dir)}
      else
        {field, :desc}
      end

    {:noreply,
     socket
     |> assign(sort_by: sort_by, sort_dir: sort_dir)
     |> load_data()}
  end

  def handle_event("toggle_roots_only", _, socket) do
    user = socket.assigns.current_user
    roots_only = !socket.assigns.roots_only

    case Accounts.update_preferences(user, %{conversations_roots_only: roots_only}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:roots_only, roots_only)
         |> load_data()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Could not save preference")}
    end
  end

  defp load_data(socket) do
    user_id = socket.assigns.current_user.id
    roots_only = socket.assigns.roots_only
    convs = Conversations.list_conversations(user_id, roots_only: roots_only)
    agents = Agents.list_agents(user_id, [])

    sorted = sort_conversations(convs, socket.assigns.sort_by, socket.assigns.sort_dir)

    assign(socket,
      conversations: sorted,
      agents_by_id: Map.new(agents, &{&1.id, &1})
    )
  end

  @epoch ~U[0000-01-01 00:00:00Z]

  defp sort_conversations(convs, field, :asc) do
    Enum.sort_by(convs, &(Map.get(&1, field) || @epoch), DateTime)
  end

  defp sort_conversations(convs, field, :desc) do
    Enum.sort_by(convs, &(Map.get(&1, field) || @epoch), {:desc, DateTime})
  end

  defp toggle_dir(:asc), do: :desc
  defp toggle_dir(:desc), do: :asc

  defp parse_sort_field("inserted_at"), do: :inserted_at
  defp parse_sort_field("updated_at"), do: :updated_at
  defp parse_sort_field(_), do: :inserted_at

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <h1 class="text-2xl font-semibold">Conversations</h1>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="toggle_roots_only"
            class={[
              "px-3 py-1 rounded text-sm font-mono border",
              if(@roots_only,
                do: "bg-[var(--color-bg-2)] text-[var(--color-text-primary)] border-[var(--color-border)]",
                else: "text-[var(--color-text-muted)] border-[var(--color-border)] hover:text-[var(--color-text-secondary)]"
              )
            ]}
          >
            {if @roots_only, do: "roots only", else: "all"}
          </button>
          <.link navigate={~p"/conversations/new"}>
            <.button>+ New conversation</.button>
          </.link>
        </div>
      </div>

      <.table
        id="conversations-table"
        rows={@conversations}
        sort_event="sort"
        sorted_by={Atom.to_string(@sort_by)}
        sorted_dir={@sort_dir}
      >
        <:empty_state>
          No conversations yet. Start one to see it here.
        </:empty_state>
        <:col :let={c} label="Status"><.badge status={c.status} /></:col>
        <:col :let={c} label="Task">
          <%= case first_prompt(c) do %>
            <% nil -> %><span class="text-[var(--color-text-muted)]">—</span>
            <% prompt -> %><div class="line-clamp-3" title={prompt}>{prompt}</div>
          <% end %>
        </:col>
        <:col :let={c} label="Agent">
          <.link navigate={~p"/conversations/#{c.id}"} class="block truncate text-[var(--color-text-primary)] hover:underline font-medium">
            {agent_name(@agents_by_id, c.agent_id)}
          </.link>
          <div class="text-xs text-[var(--color-text-muted)] font-mono">{short(c.id)}</div>
        </:col>
        <:col :let={c} label="Runtime">
          <span class="text-[var(--color-text-secondary)]">{c.runtime}</span>
        </:col>
        <:col :let={c} label="Source"><.source_badge source={c.source} /></:col>
        <:col :let={c} label="Started" sort_key="inserted_at">
          <span class="whitespace-nowrap">{relative_time(c.inserted_at)}</span>
        </:col>
        <:col :let={c} label="Last active" sort_key="updated_at">
          <span class="whitespace-nowrap">{relative_time(c.updated_at)}</span>
        </:col>
        <:col :let={c} label="">
          <div class="inline-flex gap-1 justify-end w-full">
            <.button
              :if={c.status not in ["terminated", "completed", "failed"]}
              variant="danger"
              phx-click="terminate"
              phx-value-id={c.id}
              data-confirm="Terminate this conversation?">
              Terminate
            </.button>
            <.button
              variant="secondary"
              phx-click="delete"
              phx-value-id={c.id}
              data-confirm="Delete this conversation and all its turns? This cannot be undone.">
              Delete
            </.button>
          </div>
        </:col>
      </.table>
    </div>
    """
  end

  defp agent_name(_agents_by_id, nil), do: "(no agent)"

  defp agent_name(agents_by_id, id) do
    case Map.get(agents_by_id, id) do
      nil -> "(deleted agent)"
      a -> a.name
    end
  end

  defp short(id), do: binary_part(id, 0, 8)

  defp relative_time(nil), do: ""

  defp relative_time(dt) do
    secs = max(0, DateTime.diff(DateTime.utc_now(), dt))

    cond do
      secs < 60 -> "#{secs}s ago"
      secs < 3600 -> "#{div(secs, 60)}m ago"
      secs < 86_400 -> "#{div(secs, 3600)}h ago"
      true -> "#{div(secs, 86_400)}d ago"
    end
  end

  defp first_prompt(conv) do
    case conv.turns do
      %Ecto.Association.NotLoaded{} -> nil
      [] -> nil
      [%{prompt: prompt} | _] ->
        prompt |> String.trim() |> String.replace(~r/\s+/, " ")
    end
  end

  attr :source, :string, default: "api"

  defp source_badge(%{source: "ui"} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-[var(--color-info-bg)] text-[var(--color-info-text)] border border-[var(--color-info)]">
      UI
    </span>
    """
  end

  defp source_badge(%{source: "agent"} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-[var(--color-warning-bg)] text-[var(--color-warning-text)] border border-[var(--color-warning)]">
      Agent
    </span>
    """
  end

  defp source_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-[10px] font-medium bg-[var(--color-bg-2)] text-[var(--color-text-muted)] border border-[var(--color-border)]">
      API
    </span>
    """
  end
end
