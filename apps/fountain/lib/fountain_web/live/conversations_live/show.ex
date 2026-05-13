defmodule FountainWeb.ConversationsLive.Show do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Accounts
  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, LogEvent}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    user_id = socket.assigns.current_user.id

    conv =
      try do
        Conversations.get_conversation!(id, user_id)
      rescue
        Ecto.NoResultsError -> nil
      end

    case conv do
      nil ->
        {:ok, socket |> put_flash(:error, "Conversation not found") |> push_navigate(to: ~p"/conversations")}

      conv ->
        graph = Conversations.get_conversation_tree(id)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{id}")
          root_node = Enum.find(graph, fn n -> is_nil(n.parent_id) end)
          root_id = if root_node, do: root_node.id, else: id
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conversations:graph:#{root_id}")
          Conversations.mark_read(id, user_id)
        end

        events = Conversations.list_log_events(id) |> annotate_durations()

        {:ok,
         socket
         |> assign(:page_title, "Conversation #{binary_part(id, 0, 8)}")
         |> assign(:conv, conv)
         |> assign(:events, events)
         |> assign(:turns_by_id, load_turns(id))
         |> assign(:visible_streams, MapSet.new(initial_visible_streams(socket.assigns.current_user)))
         |> assign(:view_mode, initial_view_mode(socket.assigns.current_user))
         |> assign(:prompt, "")
         |> assign(:pending_images, [])
         |> assign(:graph, graph)
         |> assign(:graph_open, false)}
    end
  end

  defp load_turns(conv_id) do
    Conversations.list_turns(conv_id)
    |> Enum.map(fn t ->
      image_count = length(t.images || [])
      Map.put(t, :image_count, image_count)
    end)
    |> Map.new(&{&1.id, &1})
  end

  defp initial_visible_streams(user) do
    case user.conversation_visible_streams do
      streams when is_list(streams) -> streams
      _ -> ["stdout", "stderr", "stage"]
    end
  end

  defp initial_view_mode(user) do
    case user.conversation_view_mode do
      mode when mode in ["chat", "pretty", "raw"] -> String.to_existing_atom(mode)
      _ -> :pretty
    end
  end

  # Pair `started`/`done` stage events by name (most recent open
  # `started` wins) and stamp the closing event with the elapsed
  # microseconds → milliseconds. Pure read-time computation; no schema
  # column needed on the way in.
  defp annotate_durations(events), do: do_annotate(events, %{}, [])

  defp do_annotate([], _open, acc), do: Enum.reverse(acc)

  defp do_annotate([%{kind: "stage", state: "started"} = ev | rest], open, acc) do
    do_annotate(rest, Map.put(open, ev.stage, ev.inserted_at), [ev | acc])
  end

  defp do_annotate([%{kind: "stage", state: state} = ev | rest], open, acc)
       when state in ["done", "failed", "interrupted"] do
    {duration_ms, open} =
      case Map.pop(open, ev.stage) do
        {nil, open} -> {nil, open}
        {start_at, open} -> {DateTime.diff(ev.inserted_at, start_at, :millisecond), open}
      end

    do_annotate(rest, open, [Map.put(ev, :duration_ms, duration_ms) | acc])
  end

  defp do_annotate([ev | rest], open, acc), do: do_annotate(rest, open, [ev | acc])

  @impl true
  def handle_info({:log_event, %LogEvent{} = ev}, socket) do
    if ev.id > last_event_id(socket.assigns.events) do
      events = annotate_durations(socket.assigns.events ++ [ev])
      # `turn started` is the only event that creates a new turn row,
      # so refetch the turns map only when one of those arrives.
      turns_by_id =
        if ev.kind == "stage" and ev.stage == "turn" and ev.state == "started" do
          load_turns(socket.assigns.conv.id)
        else
          socket.assigns.turns_by_id
        end

      {:noreply,
       socket
       |> assign(:events, events)
       |> assign(:turns_by_id, turns_by_id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:graph_updated}, socket) do
    id = socket.assigns.conv.id
    {:noreply, assign(socket, :graph, Conversations.get_conversation_tree(id))}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("images_selected", %{"images" => images}, socket) do
    {:noreply, assign(socket, :pending_images, images)}
  end

  def handle_event("send_prompt", %{"prompt" => p}, socket) when byte_size(p) > 0 do
    images =
      Enum.map(socket.assigns.pending_images || [], fn img ->
        %{"data" => img["data"], "media_type" => img["media_type"]}
      end)

    decoded_images =
      Enum.map(images, fn %{"data" => b64, "media_type" => mt} ->
        %{media_type: mt, data: Base.decode64!(b64)}
      end)

    case ConversationServer.send_prompt(socket.assigns.conv.id, p, decoded_images) do
      :ok ->
        # Refetch the conversation — wake-from-cold flips sandbox + status.
        conv = Conversations.get_conversation!(socket.assigns.conv.id, socket.assigns.current_user.id)

        {:noreply,
         socket
         |> assign(:conv, conv)
         |> assign(:prompt, "")
         |> assign(:pending_images, [])
         |> put_flash(:info, "Queued")}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "A turn is already running")}

      {:error, :gone} ->
        {:noreply, put_flash(socket, :error, "Conversation is terminated and can't be resumed")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Conversation is no longer running")}

      {:error, :no_agent} ->
        {:noreply, put_flash(socket, :error, "Conversation has no agent — can't resume")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't send: #{inspect(reason)}")}
    end
  end

  def handle_event("send_prompt", _, socket), do: {:noreply, socket}

  def handle_event("terminate", _, socket) do
    case ConversationServer.terminate(socket.assigns.conv.id) do
      :ok ->
        conv = Conversations.get_conversation!(socket.assigns.conv.id, socket.assigns.current_user.id)
        {:noreply, socket |> assign(:conv, conv) |> put_flash(:info, "Terminated")}

      _ ->
        {:noreply, put_flash(socket, :error, "Not running")}
    end
  end

  def handle_event("interrupt", _, socket) do
    case ConversationServer.interrupt(socket.assigns.conv.id) do
      :ok ->
        conv = Conversations.get_conversation!(socket.assigns.conv.id, socket.assigns.current_user.id)
        {:noreply, socket |> assign(:conv, conv) |> put_flash(:info, "Interrupted")}

      {:error, :idle} ->
        {:noreply, put_flash(socket, :error, "No turn is running")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Conversation is no longer running")}
    end
  end

  def handle_event("delete", _, socket) do
    {:ok, _} = Conversations.delete_conversation(socket.assigns.conv)

    {:noreply,
     socket
     |> put_flash(:info, "Conversation deleted")
     |> push_navigate(to: ~p"/conversations")}
  end

  def handle_event("update_prompt", %{"prompt" => p}, socket) do
    {:noreply, assign(socket, :prompt, p)}
  end

  # Toggle a stream filter pill on/off. Persists the new preference to the
  # database so it survives page reloads. Note: we name the assign
  # `:visible_streams` rather than `:streams` because Phoenix LiveView
  # reserves `:streams` for its built-in streams collection API and
  # refuses to let us shadow it.
  def handle_event("toggle_stream", %{"stream" => name}, socket) do
    visible =
      if MapSet.member?(socket.assigns.visible_streams, name) do
        MapSet.delete(socket.assigns.visible_streams, name)
      else
        MapSet.put(socket.assigns.visible_streams, name)
      end

    Accounts.update_preferences(
      socket.assigns.current_user,
      %{conversation_visible_streams: MapSet.to_list(visible)}
    )

    {:noreply, assign(socket, :visible_streams, visible)}
  end

  def handle_event("set_view_mode", %{"mode" => mode}, socket) do
    next = parse_view_mode(mode, socket.assigns.view_mode)

    Accounts.update_preferences(
      socket.assigns.current_user,
      %{conversation_view_mode: Atom.to_string(next)}
    )

    {:noreply,
     socket
     |> assign(:view_mode, next)
     |> push_event("view_mode_changed", %{mode: Atom.to_string(next)})}
  end

  def handle_event("toggle_graph", _, socket) do
    {:noreply, assign(socket, :graph_open, !socket.assigns.graph_open)}
  end

  defp parse_view_mode(mode, current) do
    case mode do
      "chat" -> :chat
      "pretty" -> :pretty
      "raw" -> :raw
      _ -> current
    end
  end

  # The `stage` pill toggles **all framework activity**: stage markers
  # (provision started/done, etc.) AND output that was emitted while a
  # framework stage was active (apt under packages, git under clone,
  # the setup script). Turn output (the runtime CLI's stream-json) is
  # always tagged `stage: "turn"` and is governed by the
  # `stdout`/`stderr` pills.
  defp event_visible?(%{kind: "stage"}, streams), do: MapSet.member?(streams, "stage")

  defp event_visible?(%{kind: "output", stage: s}, streams)
       when is_binary(s) and s != "" and s != "turn",
       do: MapSet.member?(streams, "stage")

  defp event_visible?(%{kind: "output", stream: s}, streams) when is_binary(s) and s != "",
    do: MapSet.member?(streams, s)

  defp event_visible?(_ev, _streams), do: false

  defp last_event_id([]), do: 0
  defp last_event_id(events), do: events |> List.last() |> Map.get(:id, 0)

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <div>
          <div class="text-sm text-zinc-500 font-mono">{@conv.id}</div>
          <div class="text-2xl font-semibold flex items-center gap-3">
            Conversation
            <.status_badge status={@conv.status} />
          </div>
          <div class="text-sm text-zinc-500">runtime: {@conv.runtime}</div>
          <div :if={@conv.sandbox} class="text-sm text-zinc-500 font-mono">
            sprite: {@conv.sandbox.sprite_name}
            <span class="text-zinc-400">({String.slice(@conv.sandbox.id, 0, 8)} &middot; {@conv.sandbox.status})</span>
          </div>
          <div :if={@conv.vault} class="text-sm text-zinc-500">
            vault: <.link navigate={~p"/vaults/#{@conv.vault.id}/edit"} class="font-medium underline">{@conv.vault.name}</.link>
          </div>
          <div class="text-sm text-zinc-500 flex items-center gap-1.5">
            source: <.source_badge source={@conv.source} />
          </div>
          <div :if={@conv.parent_conversation_id} class="text-sm text-zinc-500">
            spawned by:
            <.link
              navigate={~p"/conversations/#{@conv.parent_conversation_id}"}
              class="font-mono underline text-zinc-700 hover:text-zinc-900"
            >
              {String.slice(@conv.parent_conversation_id, 0, 8)}
            </.link>
          </div>
        </div>
        <div class="flex gap-2">
          <.btn_secondary :if={@conv.status == "running"}
            phx-click="interrupt" data-confirm="Stop the running turn?">
            Interrupt
          </.btn_secondary>
          <.btn_danger :if={@conv.status not in ["terminated", "completed", "failed"]}
            phx-click="terminate" data-confirm="Terminate this conversation?">
            Terminate
          </.btn_danger>
          <.btn_secondary phx-click="delete"
            data-confirm="Delete this conversation and all its turns? This cannot be undone.">
            Delete
          </.btn_secondary>
        </div>
      </div>

      <div>
        <button
          type="button"
          phx-click="toggle_graph"
          class="text-xs text-zinc-400 hover:text-zinc-200 font-mono flex items-center gap-1.5"
        >
          <span>{if @graph_open, do: "▾", else: "▸"}</span>
          <span>{if @graph_open, do: "hide graph", else: "view graph"}</span>
        </button>
        <div :if={@graph_open} class="mt-2">
          <.conversation_graph graph={@graph} conv_id={@conv.id} />
        </div>
      </div>

      <div class="flex items-center justify-between gap-2 text-xs">
        <div class={["flex items-center gap-2", @view_mode == :chat && "invisible"]}>
          <span class="text-zinc-500">show:</span>
          <.stream_pill name="stage" label="stage" active={MapSet.member?(@visible_streams, "stage")} />
          <.stream_pill name="stdout" label="stdout" active={MapSet.member?(@visible_streams, "stdout")} />
          <.stream_pill name="stderr" label="stderr" active={MapSet.member?(@visible_streams, "stderr")} />
        </div>
        <div
          id="view-mode-persist"
          class="inline-flex rounded overflow-hidden border border-zinc-300 font-mono"
          phx-hook="ViewModePersist"
          data-view-mode={@view_mode}
        >
          <.view_mode_button mode="chat" label="chat" active={@view_mode == :chat} />
          <.view_mode_button mode="pretty" label="pretty" active={@view_mode == :pretty} />
          <.view_mode_button mode="raw" label="raw" active={@view_mode == :raw} />
        </div>
      </div>

      <%= case @view_mode do %>
        <% :chat -> %>
          <div class="bg-gradient-to-b from-zinc-50 to-white rounded-lg shadow-sm border border-zinc-200 p-6 h-[60vh] overflow-y-auto"
            id="log-stream" phx-hook="ScrollBottom">
            <.chat_view turns={@turns_by_id} events={@events} conv={@conv}/>
            <div :if={map_size(@turns_by_id) == 0} class="text-zinc-400 text-sm italic">Waiting for the first turn…</div>
          </div>

        <% :raw -> %>
          <div class="bg-zinc-900 text-zinc-100 rounded shadow p-4 h-[60vh] overflow-y-auto font-mono text-xs"
            id="log-stream" phx-hook="ScrollBottom">
            <%= for ev <- @events, event_visible?(ev, @visible_streams) do %>
              <.raw_event_line event={ev}/>
            <% end %>
            <div :if={@events == []} class="text-zinc-500">Waiting for output…</div>
          </div>

        <% _ -> %>
          <div class="bg-zinc-900 text-zinc-100 rounded shadow p-4 h-[60vh] overflow-y-auto font-mono text-xs space-y-1"
            id="log-stream" phx-hook="ScrollBottom">
            <%= for node <- group_into_sections(@events, @visible_streams, @view_mode) do %>
              <.tree_node node={node} runtime={@conv.runtime} view_mode={@view_mode} turns={@turns_by_id}/>
            <% end %>
            <div :if={@events == []} class="text-zinc-500">Waiting for output…</div>
          </div>
      <% end %>

      <form phx-submit="send_prompt" phx-change="update_prompt" class="bg-white rounded shadow border border-zinc-200 p-4 space-y-3">
        <.input id="prompt" name="prompt" type="textarea" rows="3"
          value={@prompt} placeholder="Send another prompt…" phx-hook="SubmitOnCmdEnter"/>
        <div :if={@pending_images != []} class="flex flex-wrap gap-2">
          <%= for img <- @pending_images do %>
            <div class="relative group">
              <img src={img["url"]} class="h-16 w-16 object-cover rounded border border-zinc-200 cursor-pointer"
                onclick={"window.open('#{img["url"]}', '_blank')"} />
              <span class="absolute -top-1 -right-1 hidden group-hover:flex bg-zinc-800 text-white text-[9px] rounded px-1">{img["name"]}</span>
            </div>
          <% end %>
        </div>
        <div class="flex justify-between items-center gap-3">
          <label class="cursor-pointer flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-700">
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2"
                d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2 2v12a2 2 0 002 2z" />
            </svg>
            <span>{if @pending_images == [], do: "Attach images", else: "#{length(@pending_images)} image(s)"}</span>
            <input type="file" accept="image/png,image/jpeg,image/gif,image/webp" multiple class="hidden"
              id="image-picker" phx-hook="ImagePicker" />
          </label>
          <div class="flex items-center gap-3">
            <span class="text-xs text-zinc-400"><kbd class="px-1 py-0.5 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono">&#8984;</kbd> <kbd class="px-1 py-0.5 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono">Enter</kbd> to send</span>
            <.btn type="submit" phx-disable-with="Sending…">Send</.btn>
          </div>
        </div>
      </form>
    </div>
    """
  end

  attr :graph, :any, required: true
  attr :conv_id, :string, required: true

  defp conversation_graph(assigns) do
    ~H"""
    <div
      id="conversation-graph"
      phx-hook="ConversationGraph"
      phx-update="ignore"
      data-graph={Jason.encode!(@graph)}
      data-current-id={@conv_id}
      class="w-full h-[28rem] bg-zinc-900 rounded border border-zinc-800"
    />
    """
  end

  attr :mode, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, required: true

  defp view_mode_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="set_view_mode"
      phx-value-mode={@mode}
      class={[
        "px-3 py-0.5",
        if(@active,
          do: "bg-zinc-800 text-zinc-50",
          else: "bg-zinc-100 text-zinc-600 hover:bg-zinc-200"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  attr :source, :string, required: true

  defp source_badge(%{source: "ui"} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium bg-blue-100 text-blue-700">ui</span>
    """
  end

  defp source_badge(%{source: "agent"} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium bg-amber-100 text-amber-700">agent</span>
    """
  end

  defp source_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium bg-zinc-100 text-zinc-600">{@source}</span>
    """
  end

  attr :turns, :map, required: true
  attr :events, :list, required: true
  attr :conv, :map, required: true

  defp chat_view(assigns) do
    by_turn = Enum.group_by(assigns.events, & &1.turn_id)

    turns =
      assigns.turns
      |> Map.values()
      |> Enum.sort_by(& &1.turn_number)

    assigns = assign(assigns, ordered_turns: turns, events_by_turn: by_turn)

    ~H"""
    <div class="space-y-6">
      <%= for turn <- @ordered_turns do %>
        <.chat_turn turn={turn} events={Map.get(@events_by_turn, turn.id, [])} conv={@conv}/>
      <% end %>
    </div>
    """
  end

  attr :turn, :map, required: true
  attr :events, :list, required: true
  attr :conv, :map, required: true

  defp chat_turn(assigns) do
    reply = chat_assistant_reply(assigns.events, assigns.conv.runtime)
    agent_name = assigns.conv.agent && assigns.conv.agent.name
    runtime_label = assigns.conv.runtime
    image_count = Map.get(assigns.turn, :image_count, 0)

    assigns =
      assign(assigns,
        reply: reply,
        agent_name: agent_name || runtime_label,
        agent_glyph: agent_glyph(runtime_label),
        image_count: image_count
      )

    ~H"""
    <div class="space-y-3">
      <.chat_message
        role={:user}
        name="you"
        avatar="👤"
        glyph_class="bg-blue-600 text-white"
        timestamp={@turn.started_at}
      >
        <div :if={@image_count > 0} class="flex flex-wrap gap-2 mb-2">
          <%= for pos <- 0..(@image_count - 1) do %>
            <a href={"/conversations/#{@conv.id}/turns/#{@turn.id}/images/#{pos}"} target="_blank">
              <img src={"/conversations/#{@conv.id}/turns/#{@turn.id}/images/#{pos}"}
                class="max-w-[300px] max-h-[200px] object-contain rounded border border-blue-400/30" />
            </a>
          <% end %>
        </div>
        <p class="whitespace-pre-wrap m-0">{@turn.prompt}</p>
      </.chat_message>

      <.chat_message
        :if={@reply != ""}
        role={:assistant}
        name={@agent_name}
        avatar={@agent_glyph}
        glyph_class="bg-zinc-200 text-zinc-700"
        timestamp={@turn.ended_at}
      >
        <div class="prose prose-sm max-w-none prose-zinc prose-p:my-2 prose-pre:my-2 prose-headings:my-2">
          {Phoenix.HTML.raw(render_markdown(@reply))}
        </div>
      </.chat_message>

      <.chat_message
        :if={@reply == "" and @turn.status == "running"}
        role={:assistant}
        name={@agent_name}
        avatar={@agent_glyph}
        glyph_class="bg-zinc-200 text-zinc-700"
        timestamp={nil}
        muted
      >
        <div class="flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-zinc-400 animate-pulse"/>
          <span class="size-1.5 rounded-full bg-zinc-400 animate-pulse [animation-delay:200ms]"/>
          <span class="size-1.5 rounded-full bg-zinc-400 animate-pulse [animation-delay:400ms]"/>
        </div>
      </.chat_message>

      <.chat_message
        :if={@reply == "" and @turn.status not in ["running", "completed"]}
        role={:assistant}
        name={@agent_name}
        avatar={@agent_glyph}
        glyph_class="bg-zinc-200 text-zinc-700"
        timestamp={@turn.ended_at}
        muted
      >
        <span class="italic">turn {@turn.status}</span>
      </.chat_message>
    </div>
    """
  end

  attr :role, :atom, required: true
  attr :name, :string, required: true
  attr :avatar, :string, required: true
  attr :glyph_class, :string, required: true
  attr :timestamp, :any, default: nil
  attr :muted, :boolean, default: false
  slot :inner_block, required: true

  defp chat_message(assigns) do
    ~H"""
    <div class={[
      "flex gap-3 items-start",
      @role == :user && "flex-row-reverse"
    ]}>
      <div class={[
        "shrink-0 size-8 rounded-full flex items-center justify-center text-sm shadow-sm",
        @glyph_class
      ]}>
        {@avatar}
      </div>
      <div class={[
        "max-w-[78%] flex flex-col gap-1",
        @role == :user && "items-end"
      ]}>
        <div class="flex items-baseline gap-2 px-1">
          <span class="text-xs font-medium text-zinc-700">{@name}</span>
          <span :if={@timestamp} class="text-[10px] text-zinc-400 font-mono">{format_chat_time(@timestamp)}</span>
        </div>
        <div class={[
          "rounded-2xl px-4 py-2.5 text-sm shadow-sm",
          cond do
            @role == :user -> "bg-blue-600 text-white rounded-tr-sm"
            @muted -> "bg-zinc-50 border border-zinc-200 text-zinc-500 rounded-tl-sm"
            true -> "bg-white border border-zinc-200 text-zinc-900 rounded-tl-sm"
          end
        ]}>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp render_markdown(text) when is_binary(text) do
    case Earmark.as_html(text, compact_output: true, smartypants: false) do
      {:ok, html, _warnings} -> html
      {:error, html, _warnings} -> html
      _ -> Phoenix.HTML.html_escape(text) |> Phoenix.HTML.safe_to_string()
    end
  end

  defp render_markdown(_), do: ""

  defp format_chat_time(nil), do: ""

  defp format_chat_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%H:%M")
  end

  defp format_chat_time(_), do: ""

  defp agent_glyph("claude"), do: "✦"
  defp agent_glyph("codex"), do: "◇"
  defp agent_glyph("gemini"), do: "◈"
  defp agent_glyph("opencode"), do: "◉"
  defp agent_glyph(_), do: "🤖"

  # Walk this turn's events and pull out every `:text` block from each
  # runtime's stream-json. Joined so multi-message turns (claude can
  # emit several assistant messages, gemini streams deltas) read as
  # one contiguous reply.
  defp chat_assistant_reply(events, runtime) do
    events
    |> Enum.filter(&(&1.kind == "output" and &1.stream == "stdout" and is_binary(&1.data)))
    |> Enum.flat_map(&blocks_for(&1, runtime))
    |> Enum.flat_map(fn
      %{kind: :text, body: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, required: true

  defp stream_pill(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="toggle_stream"
      phx-value-stream={@name}
      class={[
        "px-2 py-0.5 rounded font-mono",
        if(@active,
          do: "bg-zinc-200 text-zinc-900 border border-zinc-300",
          else: "bg-zinc-100 text-zinc-400 border border-zinc-200 line-through"
        )
      ]}
    >
      {@label}
    </button>
    """
  end

  # ── grouping events into stage sections ───────────────────────────────────────────────

  # Walk the events list and produce a flat list of "tree nodes" where
  # each `started`-stage event opens a `:section` node that contains all
  # subsequent output events up to the matching `done`/`failed` event.
  # Anything outside an open section becomes a `:loose` node.
  #
  # `visible` is the MapSet of currently-on stream filters; same filter
  # is applied to children inside a section. In `:pretty` mode we also
  # drop the `reattach` started/done pair entirely so the post-crash
  # output it brackets shows under the resumed `turn started` section
  # that's still open from before the crash. Events are still in the
  # DB and visible in `:raw` mode.
  #
  # The grouper uses a stack so stage events nest properly:
  # `provision started` → `packages started` opens `packages` as a
  # child of `provision`, NOT as a sibling.
  defp group_into_sections(events, visible, view_mode) do
    events =
      if view_mode == :pretty do
        Enum.reject(events, &hidden_in_pretty?/1)
      else
        events
      end

    [{:root, kids}] = do_group(events, visible, [{:root, []}])
    Enum.reverse(kids)
  end

  defp hidden_in_pretty?(%{kind: "stage", stage: "reattach"}), do: true
  defp hidden_in_pretty?(_), do: false

  # End of stream — close any still-open sections (no `done` event,
  # likely because the turn is still in flight or the BEAM crashed).
  defp do_group([], _v, [{:root, _} | _] = stack), do: stack

  defp do_group([], v, [{started, kids} | rest]) when is_map(started) do
    closed = finalize_section(started, nil, Enum.reverse(kids))
    do_group([], v, stack_push_section(closed, rest))
  end

  defp do_group([%{kind: "stage", state: "started"} = ev | rest], v, stack) do
    do_group(rest, v, [{ev, []} | stack])
  end

  defp do_group([%{kind: "stage", state: state} = ev | rest], v, stack)
       when state in ["done", "failed", "interrupted"] do
    case stack do
      [{started, kids} | rest_stack] when is_map(started) and started.stage == ev.stage ->
        closed = finalize_section(started, ev, Enum.reverse(kids))
        do_group(rest, v, stack_push_section(closed, rest_stack))

      _ ->
        # Mismatched close → emit as a loose event so it isn't lost.
        do_group(rest, v, stack_push_event(ev, stack, v))
    end
  end

  defp do_group([ev | rest], v, stack) do
    do_group(rest, v, stack_push_event(ev, stack, v))
  end

  # Output events now carry the active stage in their `:stage` field
  # (set at write time). When that stage matches an open frame deeper
  # in the stack — even if that frame isn't the current top — push the
  # event into THAT frame, not the top one. This keeps e.g. apt's
  # stdout under `packages` even though `provision` is also open above
  # `packages` in the stack.
  defp stack_push_event(ev, stack, visible) do
    if event_visible?(ev, visible) do
      target = output_stage_target(ev, stack)
      insert_at(stack, target, %{kind: :event, event: ev})
    else
      stack
    end
  end

  defp output_stage_target(%{kind: "output", stage: stage}, stack)
       when is_binary(stage) and stage != "" do
    case Enum.find_index(stack, fn
           {%{stage: s}, _kids} -> s == stage
           _ -> false
         end) do
      nil -> 0
      idx -> idx
    end
  end

  defp output_stage_target(_ev, _stack), do: 0

  defp insert_at(stack, idx, child) do
    {head, [{frame, kids} | tail]} = Enum.split(stack, idx)
    head ++ [{frame, [child | kids]} | tail]
  end

  defp stack_push_section(section, stack) do
    [{frame, kids} | rest] = stack
    [{frame, [section | kids]} | rest]
  end

  defp finalize_section(started, done, children) do
    %{
      kind: :section,
      stage: started.stage,
      started: started,
      done: done,
      children: children,
      duration_ms: done && Map.get(done, :duration_ms)
    }
  end

  # ── tree node renderer ───────────────────────────────────────────────────

  attr :node, :map, required: true
  attr :runtime, :string, required: true
  attr :view_mode, :atom, required: true
  attr :turns, :map, default: %{}

  defp tree_node(%{node: %{kind: :event}} = assigns) do
    ~H"""
    <.event_line event={@node.event} runtime={@runtime} view_mode={@view_mode}/>
    """
  end

  defp tree_node(%{node: %{kind: :section}} = assigns) do
    has_kids? = assigns.node.children != []
    finished? = not is_nil(assigns.node.done)
    state = if finished?, do: assigns.node.done.state, else: "started"

    # Three child rendering modes:
    #   :cards     — the `turn` stage's children are stream-json events
    #                that we want as per-event cards (text/thinking/tool/etc).
    #   :recursive — the section contains nested sections (e.g. `provision`
    #                wraps `packages`/`clone`/`setup`); render children as
    #                their own tree_nodes so the nesting is visible.
    #   :text      — leaf section with only output children (shell output);
    #                flatten into a single inline `<pre>` block.
    has_section? = Enum.any?(assigns.node.children, &(&1.kind == :section))

    child_mode =
      cond do
        assigns.node.stage == "turn" -> :cards
        has_section? -> :recursive
        true -> :text
      end

    # Open by default for the conversation `turn`, sections still in
    # progress, and container sections (so the user can see what's
    # nested inside without an extra click). Finished leaf sections
    # (`packages`, `setup`, ...) start collapsed.
    open? = not finished? or child_mode in [:cards, :recursive]

    # For `turn` sections we look up the prompt the user submitted for
    # this turn (the `turn started` event carries `turn_id` in its data
    # blob) and render it as the lead element inside the section.
    turn_prompt =
      if assigns.node.stage == "turn",
        do: lookup_turn_prompt(assigns.node.started, assigns.turns),
        else: nil

    assigns =
      assign(assigns,
        has_kids?: has_kids?,
        state: state,
        child_mode: child_mode,
        open?: open?,
        turn_prompt: turn_prompt
      )

    ~H"""
    <details open={@open?} class="group">
      <summary class={[
        "cursor-pointer flex items-center gap-3 text-xs",
        not @has_kids? && "list-none cursor-default"
      ]}>
        <span class="w-3 text-zinc-500">
          <span :if={@has_kids?}>&#9662;</span>
        </span>
        <span class="w-5 text-center">{stage_icon(@node.stage)}</span>
        <span class="font-mono text-zinc-200 w-44 truncate">{@node.stage}</span>
        <span class={["w-20", stage_state_class(@state)]}>{@state}</span>
        <span class="text-zinc-500 font-mono w-20 text-right">{format_section_duration(@node)}</span>
        <span class="text-zinc-600 font-mono truncate">{stage_extra(@node.started)}</span>
      </summary>
      <div :if={@has_kids? or @turn_prompt} class="pl-8 mt-1 mb-2 border-l border-zinc-800">
        <div :if={@turn_prompt} class="bg-zinc-800/60 border border-zinc-700 rounded px-3 py-2 mb-2">
          <div class="text-zinc-500 text-[10px] uppercase tracking-wide mb-1">&#128100; prompt</div>
          <pre class="whitespace-pre-wrap text-zinc-100 text-xs">{@turn_prompt}</pre>
        </div>
        <%= case @child_mode do %>
          <% :text -> %>
            <pre class="whitespace-pre-wrap text-xs text-zinc-400 leading-snug py-1"><%= for child <- @node.children do %><span class={section_child_class(child.event)}>{child.event.data}</span><% end %></pre>
          <% :cards -> %>
            <div class="space-y-1">
              <%= for block <- turn_blocks(@node.children, @runtime) do %>
                <.block_row block={block} stream="stdout"/>
              <% end %>
            </div>
          <% _ -> %>
            <div class="space-y-1">
              <%= for child <- @node.children do %>
                <.tree_node node={child} runtime={@runtime} view_mode={@view_mode} turns={@turns}/>
              <% end %>
            </div>
        <% end %>
      </div>
    </details>
    """
  end

  # Color hint for a chunk inside a flattened (text) section: stderr in
  # red, stdout / unknown in default zinc.
  defp section_child_class(%{kind: "output", stream: "stderr"}), do: "text-rose-300"
  defp section_child_class(_), do: ""

  # Flat per-event row used by raw mode. No grouping, no cards, no
  # prompt overlay — just the bytes as they were stored, with a small
  # gutter so the user can tell stage / stdout / stderr apart and
  # follow-event ordering.
  attr :event, :map, required: true

  defp raw_event_line(%{event: %{kind: "stage"}} = assigns) do
    ~H"""
    <div class="flex gap-3 py-0.5">
      <span class="text-zinc-600 text-[10px] w-12 text-right font-mono">#{@event.id}</span>
      <span class="text-amber-400 w-16">stage</span>
      <span class="text-zinc-300">{@event.stage} {@event.state} {@event.data}</span>
    </div>
    """
  end

  defp raw_event_line(%{event: %{kind: "output"}} = assigns) do
    {tag, tag_class} = raw_output_tag(assigns.event)
    assigns = assign(assigns, tag: tag, tag_class: tag_class)

    ~H"""
    <div class="flex gap-3 py-0.5">
      <span class="text-zinc-600 text-[10px] w-12 text-right font-mono">#{@event.id}</span>
      <span class={["w-16", @tag_class]}>{@tag}</span>
      <pre class={[
        "whitespace-pre-wrap flex-1",
        if(@event.stream == "stderr", do: "text-rose-300", else: "text-zinc-300")
      ]}>{@event.data}</pre>
    </div>
    """
  end

  # Raw-row label for an output event:
  #   - framework stage (apt under packages, etc.) → show the stage
  #     name in the same amber as stage markers
  #   - turn output → show the stream (stdout/stderr) like before
  defp raw_output_tag(%{stage: s, stream: stream})
       when is_binary(s) and s != "" and s != "turn" do
    color = if stream == "stderr", do: "text-rose-400", else: "text-amber-400"
    {s, color}
  end

  defp raw_output_tag(%{stream: "stderr"}), do: {"stderr", "text-rose-400"}
  defp raw_output_tag(_), do: {"stdout", "text-emerald-400"}

  attr :event, :map, required: true
  attr :runtime, :string, required: true
  attr :view_mode, :atom, required: true

  defp event_line(%{event: %{kind: "stage"}} = assigns) do
    ~H"""
    <div class="flex items-center gap-3 text-xs">
      <span class="w-5 text-center">{stage_icon(@event.stage)}</span>
      <span class="font-mono text-zinc-300 w-44 truncate">{@event.stage}</span>
      <span class={["w-20", stage_state_class(@event.state)]}>{@event.state}</span>
      <span class="text-zinc-500 font-mono w-20 text-right">{format_duration(@event)}</span>
      <span class="text-zinc-600 font-mono truncate">{stage_extra(@event)}</span>
    </div>
    """
  end

  defp event_line(%{view_mode: :raw} = assigns) do
    ~H"""
    <pre class={[
      "whitespace-pre-wrap text-xs",
      if(@event.stream == "stderr", do: "text-rose-300", else: "text-zinc-300")
    ]}>{@event.data}</pre>
    """
  end

  # :pretty — explode the event into typed blocks (one per JSON line ×
  # one per content item) and render each on its own row with an icon
  # and (where useful) a collapsible payload.
  defp event_line(assigns) do
    blocks = blocks_for(assigns.event, assigns.runtime)
    assigns = assign(assigns, :blocks, blocks)

    ~H"""
    <%= for block <- @blocks do %>
      <.block_row block={block} stream={@event.stream} />
    <% end %>
    """
  end

  attr :block, :map, required: true
  attr :stream, :string, default: nil

  # ── per-block renderers ────────────────────────────────────────────────────

  defp block_row(%{block: %{kind: :init}} = assigns) do
    ~H"""
    <details class="text-zinc-400 text-xs">
      <summary class="cursor-pointer">&#8857; {@block.summary}</summary>
      <pre :if={@block[:body]} class="ml-4 mt-1 text-zinc-500 whitespace-pre-wrap">{@block.body}</pre>
    </details>
    """
  end

  defp block_row(%{block: %{kind: :thinking}} = assigns) do
    ~H"""
    <div class="text-zinc-400 italic whitespace-pre-wrap pl-3 border-l border-zinc-700">
      <span class="not-italic text-zinc-500 mr-1">&#127744; thinking</span>
      {@block.body}
    </div>
    """
  end

  defp block_row(%{block: %{kind: :tool_use}} = assigns) do
    ~H"""
    <details class="border border-zinc-700 rounded px-2 py-1">
      <summary class="cursor-pointer text-zinc-200 flex items-center gap-2">
        <span class="text-zinc-400">&#128295;</span>
        <span class="font-semibold">{@block.name}</span>
        <span :if={@block[:summary]} class="text-zinc-500 truncate flex-1">{@block.summary}</span>
        <span :if={@block[:result] && @block.result.error?} class="text-rose-300 text-[10px] shrink-0">error</span>
        <span :if={@block[:result] && not @block.result.error?} class="text-emerald-400 text-[10px] shrink-0">&#10003;</span>
      </summary>
      <div class="mt-1 space-y-1">
        <div class="text-zinc-500 text-[10px] uppercase tracking-wider">input</div>
        <pre class="text-zinc-300 whitespace-pre-wrap text-xs">{@block.body}</pre>
        <div :if={@block[:result]} class="text-zinc-500 text-[10px] uppercase tracking-wider mt-1">result</div>
        <pre :if={@block[:result]} class={[
          "whitespace-pre-wrap text-xs",
          if(@block.result.error?, do: "text-rose-300", else: "text-zinc-300")
        ]}>{@block.result.body}</pre>
      </div>
    </details>
    """
  end

  # Orphan tool_result (no matching tool_use seen, e.g. resumed
  # mid-conversation). Rare; render as a stand-alone indented block.
  defp block_row(%{block: %{kind: :tool_result}} = assigns) do
    ~H"""
    <div class={[
      "whitespace-pre-wrap pl-3 border-l border-zinc-700",
      if(@block[:error?], do: "text-rose-300", else: "text-zinc-300")
    ]}>
      <span class="text-zinc-500 mr-1">&#8594;</span>{@block.body}
    </div>
    """
  end

  defp block_row(%{block: %{kind: :text}} = assigns) do
    ~H"""
    <div class="text-zinc-100 whitespace-pre-wrap">{@block.body}</div>
    """
  end

  defp block_row(%{block: %{kind: :result}} = assigns) do
    ~H"""
    <details class="text-emerald-300">
      <summary class="cursor-pointer">&#10003; {@block.body}</summary>
      <pre :if={@block[:raw]} class="ml-4 mt-1 text-zinc-500 whitespace-pre-wrap text-xs">{@block.raw}</pre>
    </details>
    """
  end

  defp block_row(%{block: %{kind: :error}} = assigns) do
    ~H"""
    <div class="text-rose-300">&#10007; {@block.body}</div>
    """
  end

  # Fallback — unknown JSON or the event was a stream we don't have a
  # pretty rule for yet. Shows the raw line so nothing is hidden, but
  # styled lighter so it stands out as "we don't know what this is".
  defp block_row(%{block: %{kind: :raw}} = assigns) do
    ~H"""
    <details class={[
      "text-xs",
      if(@stream == "stderr", do: "text-rose-300/80", else: "text-zinc-500")
    ]}>
      <summary class="cursor-pointer truncate">{@block[:summary] || "raw"}</summary>
      <pre class="ml-4 mt-1 whitespace-pre-wrap">{@block.body}</pre>
    </details>
    """
  end

  # ── event → blocks ──────────────────────────────────────────────

  # Splits an event's `data` (which may be a stream-json chunk with N
  # lines) into a flat list of structured blocks. Each block is a map
  # with at least `:kind`, plus kind-specific fields.
  defp blocks_for(%{data: data}, runtime) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&line_to_blocks(&1, runtime))
  end

  defp blocks_for(_, _), do: []

  # Flatten a turn section's children into a single ordered block list,
  # then collapse each tool_use ↔ tool_result pair (matched by id) into
  # a single tool_use block with the result tucked inside. The orphan
  # tool_result fallback handles cases where we can't find a match
  # (replayed mid-stream, runtime didn't emit an id).
  defp turn_blocks(children, runtime) do
    children
    |> Enum.flat_map(fn
      %{kind: :event, event: ev} -> blocks_for(ev, runtime)
      _ -> []
    end)
    |> pair_tool_results()
  end

  defp pair_tool_results(blocks) do
    # Index tool_result blocks by tool_id so each tool_use can attach
    # its match in one pass without quadratic walking.
    results =
      blocks
      |> Enum.filter(&(&1.kind == :tool_result and is_binary(Map.get(&1, :tool_id))))
      |> Map.new(fn r -> {r.tool_id, r} end)

    blocks
    |> Enum.reduce({[], MapSet.new()}, fn block, {acc, consumed} ->
      cond do
        block.kind == :tool_use and is_binary(Map.get(block, :id)) and
            Map.has_key?(results, block.id) ->
          r = Map.fetch!(results, block.id)
          merged = Map.put(block, :result, %{body: r.body, error?: Map.get(r, :error?, false)})
          {[merged | acc], MapSet.put(consumed, block.id)}

        block.kind == :tool_result and is_binary(Map.get(block, :tool_id)) and
            MapSet.member?(consumed, block.tool_id) ->
          # already tucked into the matching tool_use card; drop it.
          {acc, consumed}

        true ->
          {[block | acc], consumed}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp line_to_blocks(line, runtime) do
    case Jason.decode(line) do
      {:ok, decoded} ->
        case event_blocks(runtime, decoded) do
          nil -> [%{kind: :raw, body: line, summary: short_kind(decoded)}]
          blocks when is_list(blocks) -> blocks
        end

      {:error, _} ->
        [%{kind: :raw, body: line, summary: "raw"}]
    end
  end

  defp short_kind(%{"type" => t}), do: to_string(t)
  defp short_kind(_), do: "raw"

  # ── claude (stream-json) ────────────────────────────────────────────────────────────
  defp event_blocks("claude", %{"type" => "system", "subtype" => "init"} = ev) do
    model = ev["model"]

    tool_count =
      ev["tools"]
      |> case do
        l when is_list(l) -> length(l)
        _ -> nil
      end

    summary =
      ["session started", model, tool_count && "#{tool_count} tools"]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [%{kind: :init, summary: summary, body: Jason.encode!(ev, pretty: true)}]
  end

  defp event_blocks("claude", %{"type" => "assistant", "message" => %{"content" => content}}) do
    Enum.flat_map(content, fn
      %{"type" => "text", "text" => t} ->
        [%{kind: :text, body: t}]

      %{"type" => "thinking", "thinking" => t} ->
        [%{kind: :thinking, body: t}]

      %{"type" => "tool_use", "name" => name, "input" => input} = tu ->
        [
          %{
            kind: :tool_use,
            id: tu["id"],
            name: name,
            summary: tool_input_preview(input),
            body: Jason.encode!(input, pretty: true)
          }
        ]

      _ ->
        []
    end)
  end

  defp event_blocks("claude", %{"type" => "user", "message" => %{"content" => content}}) do
    Enum.flat_map(content, fn
      %{"tool_use_id" => tid, "content" => c} = tr when is_binary(c) ->
        [%{kind: :tool_result, tool_id: tid, body: c, error?: tr["is_error"] == true}]

      %{"tool_use_id" => tid, "content" => list} = tr when is_list(list) ->
        [
          %{
            kind: :tool_result,
            tool_id: tid,
            body: Enum.map_join(list, "\n", &content_part_to_text/1),
            error?: tr["is_error"] == true
          }
        ]

      _ ->
        []
    end)
  end

  defp event_blocks("claude", %{"type" => "result"} = ev) do
    bits =
      [
        format_status(ev["subtype"]),
        ev["duration_ms"] && format_duration_ms(ev["duration_ms"]),
        ev["usage"] && "in:#{ev["usage"]["input_tokens"]} out:#{ev["usage"]["output_tokens"]}"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    # Body is intentionally left out here — it's a copy of the final
    # assistant message which we already rendered as a :text block.
    [%{kind: :result, body: bits, raw: Jason.encode!(ev, pretty: true)}]
  end

  defp event_blocks("claude", %{"type" => "rate_limit_event"}), do: []

  # ── codex (`codex exec --json`) ────────────────────────────────────────────────────────
  defp event_blocks("codex", %{"type" => "thread.started", "thread_id" => id}),
    do: [%{kind: :init, summary: "thread: #{id}"}]

  defp event_blocks("codex", %{"type" => "turn.started"}), do: []
  defp event_blocks("codex", %{"type" => "item.started"}), do: []

  defp event_blocks("codex", %{
         "type" => "item.completed",
         "item" => %{"type" => "agent_message", "text" => text}
       }),
       do: [%{kind: :text, body: text}]

  defp event_blocks("codex", %{"type" => "item.completed", "item" => %{"type" => t} = item}),
    do: [%{kind: :tool_use, name: to_string(t), body: Jason.encode!(item, pretty: true)}]

  defp event_blocks("codex", %{"type" => "turn.completed", "usage" => usage}),
    do: [
      %{
        kind: :result,
        body: "in:#{usage["input_tokens"]} out:#{usage["output_tokens"]}"
      }
    ]

  defp event_blocks("codex", %{"type" => "turn.failed", "error" => %{"message" => m}}),
    do: [%{kind: :error, body: m}]

  defp event_blocks("codex", %{"type" => "error", "message" => m}),
    do: [%{kind: :error, body: m}]

  # ── gemini (`gemini --output-format stream-json`) ──────────────────────────
  defp event_blocks("gemini", %{"type" => "init"} = ev) do
    summary =
      ["session started", ev["model"]]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [%{kind: :init, summary: summary, body: Jason.encode!(ev, pretty: true)}]
  end

  defp event_blocks("gemini", %{"type" => "message", "role" => "user"}), do: []

  defp event_blocks("gemini", %{"type" => "message", "role" => "assistant", "content" => c})
       when is_binary(c),
       do: [%{kind: :text, body: c}]

  defp event_blocks("gemini", %{"type" => "tool_use"} = ev) do
    [
      %{
        kind: :tool_use,
        id: ev["tool_id"],
        name: ev["tool_name"],
        summary: tool_input_preview(ev["parameters"]),
        body: Jason.encode!(ev["parameters"] || %{}, pretty: true)
      }
    ]
  end

  defp event_blocks("gemini", %{"type" => "tool_result", "output" => out} = ev)
       when is_binary(out),
       do: [
         %{
           kind: :tool_result,
           tool_id: ev["tool_id"],
           body: out,
           error?: ev["status"] != "success"
         }
       ]

  defp event_blocks("gemini", %{"type" => "result"} = ev) do
    stats = ev["stats"] || %{}

    bits =
      [
        ev["status"] && to_string(ev["status"]),
        stats["duration_ms"] && format_duration_ms(stats["duration_ms"]),
        stats["total_tokens"] && "#{stats["total_tokens"]} tokens"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" · ")

    [%{kind: :result, body: bits, raw: Jason.encode!(ev, pretty: true)}]
  end

  # ── opencode (`opencode run --format json`) ───────────────────────────────────
  defp event_blocks("opencode", %{"type" => "step_start"}), do: []

  defp event_blocks("opencode", %{"type" => "text", "part" => %{"text" => t}})
       when is_binary(t),
       do: [%{kind: :text, body: t}]

  defp event_blocks("opencode", %{
         "type" => "tool_use",
         "part" => %{"tool" => name, "state" => %{"input" => input}}
       }),
       do: [
         %{
           kind: :tool_use,
           name: name,
           summary: tool_input_preview(input),
           body: Jason.encode!(input, pretty: true)
         }
       ]

  defp event_blocks("opencode", %{"type" => "tool_use", "part" => %{"tool" => name}}),
    do: [%{kind: :tool_use, name: name}]

  defp event_blocks("opencode", %{"type" => "step_finish", "part" => %{"reason" => reason}} = ev),
    do: [%{kind: :result, body: reason, raw: Jason.encode!(ev, pretty: true)}]

  # Unknown — caller falls back to a :raw block.
  defp event_blocks(_runtime, _decoded), do: nil

  # Small helpers
  defp content_part_to_text(%{"type" => "text", "text" => t}), do: t
  defp content_part_to_text(other), do: Jason.encode!(other)

  # One-line preview of a tool's input for display next to the tool name.
  defp tool_input_preview(input) when is_map(input) do
    cond do
      Map.has_key?(input, "command") -> to_string(input["command"]) |> truncate(80)
      Map.has_key?(input, "file_path") -> to_string(input["file_path"])
      Map.has_key?(input, "pattern") -> to_string(input["pattern"])
      true -> input |> Jason.encode!() |> truncate(80)
    end
  end

  defp tool_input_preview(_), do: nil

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n,
    do: binary_part(s, 0, n) <> "…"

  defp truncate(s, _), do: s

  # ── stage row helpers ───────────────────────────────────────────────────────

  defp stage_icon("provision"), do: "&#10024;"
  defp stage_icon("checkpoint_restore"), do: "&#128230;"
  defp stage_icon("setup"), do: "&#128736;"
  defp stage_icon("packages"), do: "&#128280;"
  defp stage_icon("network"), do: "&#127760;"
  defp stage_icon("clone"), do: "&#129319;"
  defp stage_icon("turn"), do: "&#128172;"
  defp stage_icon("reattach"), do: "&#128268;"
  defp stage_icon("terminate"), do: "&#128721;"
  defp stage_icon(_), do: "&bull;"

  defp stage_state_class("started"), do: "text-zinc-400"
  defp stage_state_class("done"), do: "text-emerald-400"
  defp stage_state_class("failed"), do: "text-rose-400"
  defp stage_state_class("interrupted"), do: "text-amber-400"
  defp stage_state_class(_), do: "text-zinc-500"

  defp format_duration(%{state: "started"}), do: "…"
  defp format_duration(%{duration_ms: nil}), do: ""
  defp format_duration(%{duration_ms: ms}), do: format_duration_ms(ms)
  defp format_duration(_), do: ""

  defp format_section_duration(%{done: nil}), do: "…"
  defp format_section_duration(%{duration_ms: nil}), do: ""
  defp format_section_duration(%{duration_ms: ms}), do: format_duration_ms(ms)

  defp format_duration_ms(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"
  defp format_duration_ms(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration_ms(_), do: ""

  # Optional one-liner appended to a stage row from its `data` payload —
  # e.g. `provision_setup` shows `exit_code:0`, `clone` shows `count:3`.
  defp stage_extra(%{data: data}) when is_binary(data) and data not in ["", "{}"] do
    case Jason.decode(data) do
      {:ok, %{} = m} when map_size(m) > 0 ->
        m
        |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{format_extra_val(v)}" end)
        |> truncate(120)

      _ ->
        ""
    end
  end

  defp stage_extra(_), do: ""

  defp format_extra_val(v) when is_binary(v), do: truncate(v, 40)
  defp format_extra_val(v), do: inspect(v)

  defp format_status(nil), do: nil
  defp format_status(s), do: to_string(s)

  # Pull the turn_id out of the `turn started` event's JSON data and
  # look up the prompt the user submitted for that turn. Returns the
  # prompt string or nil if unavailable.
  defp lookup_turn_prompt(%{data: data}, turns_by_id) when is_binary(data) do
    case Jason.decode(data) do
      {:ok, %{"turn_id" => id}} ->
        case Map.get(turns_by_id, id) do
          %{prompt: p} when is_binary(p) and p != "" -> p
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp lookup_turn_prompt(_, _), do: nil
end
