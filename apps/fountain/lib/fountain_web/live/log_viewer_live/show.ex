defmodule FountainWeb.LogViewerLive.Show do
  use FountainWeb, :live_view

  alias Fountain.Conversations

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user = socket.assigns.current_user

    conversation =
      try do
        Conversations.get_conversation!(id, user.id)
      rescue
        Ecto.NoResultsError -> nil
      end

    if conversation do
      if connected?(socket) do
        Phoenix.PubSub.subscribe(
          Fountain.PubSub,
          "conv:#{user.id}:#{conversation.id}"
        )
      end

      logs = Conversations.list_log_events(conversation.id)

      {:ok,
       socket
       |> assign(:page_title, "Logs — #{String.slice(conversation.id, 0, 8)}")
       |> assign(:conversation, conversation)
       |> assign(:logs, logs)}
    else
      {:ok,
       socket
       |> put_flash(:error, "Conversation not found")
       |> push_navigate(to: ~p"/conversations")}
    end
  end

  @impl true
  def handle_info({:log_event, event}, socket) do
    {:noreply, update(socket, :logs, fn logs -> logs ++ [event] end)}
  end

  def handle_info({:conversation_updated, conv}, socket) do
    {:noreply, assign(socket, :conversation, conv)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div class="flex items-center gap-3">
          <.link navigate={~p"/conversations/#{@conversation.id}"} class="text-zinc-500 hover:text-zinc-900 text-sm">
            ← Conversation
          </.link>
          <h1 class="text-lg font-semibold font-mono">
            logs / {String.slice(@conversation.id, 0, 8)}
          </h1>
        </div>
        <span class={[
          "inline-flex items-center rounded px-2 py-0.5 text-xs font-medium border",
          status_color(@conversation.status)
        ]}>
          {@conversation.status}
        </span>
      </div>

      <div
        id="log-container"
        phx-hook="LogScroll"
        class="bg-zinc-950 text-zinc-100 rounded-lg border border-zinc-800 font-mono text-xs p-4 h-[70vh] overflow-y-auto">
        <div :if={@logs == []} class="text-zinc-500 italic">No log output yet.</div>
        <div :for={event <- @logs} class={["leading-5", log_line_class(event)]}>
          <span class="text-zinc-500 select-none mr-3">{format_ts(event.inserted_at)}</span>
          <span :if={event.kind == "stage"} class="text-yellow-400">[stage:{event.stage}:{event.state}]</span>
          <span :if={event.kind != "stage"} class={log_stream_class(event.stream)}>[{event.stream}]</span>
          <span class="ml-2 whitespace-pre-wrap">{event.data}</span>
        </div>
      </div>

      <p class="text-xs text-zinc-500">
        {length(@logs)} events · auto-scrolls to bottom · updates via PubSub
      </p>
    </div>
    """
  end

  defp status_color("ready"), do: "bg-green-100 text-green-800 border-green-200"
  defp status_color("running"), do: "bg-blue-100 text-blue-800 border-blue-200"
  defp status_color("failed"), do: "bg-red-100 text-red-700 border-red-200"
  defp status_color("terminated"), do: "bg-zinc-100 text-zinc-500 border-zinc-200"
  defp status_color(_), do: "bg-zinc-100 text-zinc-500 border-zinc-200"

  defp log_line_class(%{stream: "stderr"}), do: "text-red-400"
  defp log_line_class(_), do: ""

  defp log_stream_class("stderr"), do: "text-red-500"
  defp log_stream_class("stdout"), do: "text-green-500"
  defp log_stream_class(_), do: "text-zinc-500"

  defp format_ts(nil), do: ""
  defp format_ts(dt), do: Calendar.strftime(dt, "%H:%M:%S")
end
