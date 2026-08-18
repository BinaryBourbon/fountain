defmodule FountainWeb.ConversationsLive.Show do
  @moduledoc false
  use FountainWeb, :live_view

  alias Fountain.Accounts
  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, LogEvent}

  # The chat-mode bubbles and the event→blocks seam live in `Chat`, shared
  # with the team page.
  import FountainWeb.ConversationsLive.Chat, only: [chat_view: 1, blocks_for: 2]

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
        {:ok,
         socket
         |> put_flash(:error, "Conversation not found")
         |> push_navigate(to: ~p"/conversations")}

      conv ->
        graph = Conversations.get_conversation_tree(id, socket.assigns.current_user.id)

        if connected?(socket) do
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{id}")
          root_node = Enum.find(graph, fn n -> is_nil(n.parent_id) end)
          root_id = if root_node, do: root_node.id, else: id
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conversations:graph:#{root_id}")
          Conversations.mark_read(id, user_id)
        end

        # Ownership: established by the scoped get_conversation in mount above.
        events = Conversations._unsafe_list_log_events(id) |> annotate_durations()

        {:ok,
         socket
         |> assign(:page_title, "Conversation #{binary_part(id, 0, 8)}")
         |> assign(:conv, conv)
         |> assign(:events, events)
         |> assign(:turns_by_id, load_turns(id))
         |> assign(
           :visible_streams,
           MapSet.new(initial_visible_streams(socket.assigns.current_user))
         )
         |> assign(:view_mode, initial_view_mode(socket.assigns.current_user))
         |> assign(:prompt, "")
         |> assign(:pending_images, [])
         |> assign(:graph, graph)
         |> assign(:graph_open, false)}
    end
  end

  defp load_turns(conv_id) do
    # Ownership: only called from mount/handle_info after the scoped
    # get_conversation.
    Conversations._unsafe_list_turns(conv_id)
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

      # Stage events are exactly when the server rewrites conversation.status,
      # and everything in the header (badge, Interrupt/Terminate visibility)
      # keys off @conv — which was loaded once at mount and never again, so
      # the page showed "pending" through a whole run and kept Interrupt
      # rendered after the turn ended (#401).
      conv =
        if ev.kind == "stage" do
          Conversations.get_conversation(socket.assigns.conv.id, socket.assigns.current_user.id) ||
            socket.assigns.conv
        else
          socket.assigns.conv
        end

      {:noreply,
       socket
       |> assign(:conv, conv)
       |> assign(:events, events)
       |> assign(:turns_by_id, turns_by_id)}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def handle_info({:graph_updated}, socket) do
    id = socket.assigns.conv.id

    {:noreply,
     assign(
       socket,
       :graph,
       Conversations.get_conversation_tree(id, socket.assigns.current_user.id)
     )}
  end

  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The read-only contract for past_due/canceled (#505, ADR 0006): viewing is
  # open, so the gate moved from the router to the events that create spend.
  # The composer is hidden in the template, but events can still be sent by
  # hand (#399's lesson). terminate/interrupt stay allowed — they STOP spend,
  # and blocking a lapsed user from ending a running sprite would protect
  # spend in reverse. delete stays allowed — removing data isn't consumption.
  @spend_events ~w(send_prompt update_prompt images_selected)

  @impl true
  def handle_event(event, _params, %{assigns: %{subscription_active: false}} = socket)
      when event in @spend_events do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Your subscription is inactive — this conversation is read-only. Update billing to send prompts."
     )}
  end

  def handle_event("images_selected", %{"images" => images}, socket) do
    {:noreply, assign(socket, :pending_images, images)}
  end

  def handle_event("send_prompt", %{"prompt" => p}, socket) when byte_size(p) > 0 do
    images =
      Enum.map(socket.assigns.pending_images || [], fn img ->
        %{"data" => img["data"], "media_type" => img["media_type"]}
      end)

    # Same validation as the API path (media-type allowlist, non-raising
    # base64, 10MB cap). This used to Base.decode64! whatever the client
    # sent, so malformed input crashed the LiveView process — and crash
    # reports log socket assigns.
    case FountainWeb.PromptImages.decode(images) do
      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}

      {:ok, decoded_images} ->
        send_decoded_prompt(socket, p, decoded_images)
    end
  end

  def handle_event("send_prompt", _, socket), do: {:noreply, socket}

  def handle_event("terminate", _, socket) do
    case ConversationServer.terminate_conversation(
           socket.assigns.conv.id,
           FountainWeb.Audited.attribution(socket)
         ) do
      :ok ->
        conv =
          Conversations.get_conversation!(socket.assigns.conv.id, socket.assigns.current_user.id)

        {:noreply, socket |> assign(:conv, conv) |> put_flash(:info, "Terminated")}

      _ ->
        {:noreply, put_flash(socket, :error, "Not running")}
    end
  end

  def handle_event("interrupt", _, socket) do
    case ConversationServer.interrupt(
           socket.assigns.conv.id,
           FountainWeb.Audited.attribution(socket)
         ) do
      :ok ->
        conv =
          Conversations.get_conversation!(socket.assigns.conv.id, socket.assigns.current_user.id)

        {:noreply, socket |> assign(:conv, conv) |> put_flash(:info, "Interrupted")}

      {:error, :idle} ->
        {:noreply, put_flash(socket, :error, "No turn is running")}

      {:error, :not_running} ->
        {:noreply, put_flash(socket, :error, "Conversation is no longer running")}
    end
  end

  def handle_event("delete", _, socket) do
    # Re-fetch instead of deleting the mount-time struct: a row already
    # deleted from another tab or the API raised StaleEntryError and killed
    # the LiveView (#401). Already-gone means the user got what they wanted.
    case Conversations.get_conversation(socket.assigns.conv.id, socket.assigns.current_user.id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:info, "Conversation already deleted")
         |> push_navigate(to: ~p"/conversations")}

      conv ->
        {:ok, _} =
          Conversations.delete_conversation(conv, FountainWeb.Audited.attribution(socket))

        {:noreply,
         socket
         |> put_flash(:info, "Conversation deleted")
         |> push_navigate(to: ~p"/conversations")}
    end
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

  # ACP rows are the model's output channel, exactly what stdout is on the
  # legacy path — so they follow the stdout pill rather than getting a pill
  # of their own. Keying on a literal "acp" entry instead would hide every
  # ACP turn for users whose persisted visible_streams predate the flag
  # (the default list only applies when nothing is saved), which is how ACP
  # conversations shipped invisible in all three view modes.
  defp event_visible?(%{kind: "output", stream: "acp"}, streams),
    do: MapSet.member?(streams, "stdout")

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
            Conversation <.status_badge status={@conv.status} />
          </div>
          <div class="text-sm text-zinc-500">runtime: {@conv.runtime}</div>
          <div :if={@conv.sandbox} class="text-sm text-zinc-500 font-mono">
            sprite: {@conv.sandbox.sprite_name} ({@conv.sandbox.provider})
            <span class="text-zinc-400">
              ({String.slice(@conv.sandbox.id, 0, 8)} &middot; {@conv.sandbox.status})
            </span>
          </div>
          <div :if={@conv.vault} class="text-sm text-zinc-500">
            vault:
            <.link navigate={~p"/vaults/#{@conv.vault.id}/edit"} class="font-medium underline">
              {@conv.vault.name}
            </.link>
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
          <.btn_secondary
            :if={@conv.status == "running"}
            phx-click="interrupt"
            data-confirm="Stop the running turn?"
          >
            Interrupt
          </.btn_secondary>
          <.btn_danger
            :if={@conv.status not in ["terminated", "failed"]}
            phx-click="terminate"
            data-confirm="Terminate this conversation?"
          >
            Terminate
          </.btn_danger>
          <.btn_secondary
            phx-click="delete"
            data-confirm="Delete this conversation and all its turns? This cannot be undone."
          >
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
          <.stream_pill
            name="stdout"
            label="stdout"
            active={MapSet.member?(@visible_streams, "stdout")}
          />
          <.stream_pill
            name="stderr"
            label="stderr"
            active={MapSet.member?(@visible_streams, "stderr")}
          />
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
          <div
            class="bg-gradient-to-b from-zinc-50 to-white rounded-lg shadow-sm border border-zinc-200 p-6 h-[60vh] overflow-y-auto"
            id="log-stream"
            phx-hook="ScrollBottom"
          >
            <.chat_view turns={@turns_by_id} events={@events} conv={@conv} />
            <div :if={map_size(@turns_by_id) == 0} class="text-zinc-400 text-sm italic">
              Waiting for the first turn…
            </div>
          </div>
        <% :raw -> %>
          <div
            class="bg-zinc-900 text-zinc-100 rounded shadow p-4 h-[60vh] overflow-y-auto font-mono text-xs"
            id="log-stream"
            phx-hook="ScrollBottom"
          >
            <%= for ev <- @events, event_visible?(ev, @visible_streams) do %>
              <.raw_event_line event={ev} />
            <% end %>
            <div :if={@events == []} class="text-zinc-500">Waiting for output…</div>
          </div>
        <% _ -> %>
          <div
            class="bg-zinc-900 text-zinc-100 rounded shadow p-4 h-[60vh] overflow-y-auto font-mono text-xs space-y-1"
            id="log-stream"
            phx-hook="ScrollBottom"
          >
            <%= for node <- group_into_sections(@events, @visible_streams, @view_mode) do %>
              <.tree_node
                node={node}
                runtime={@conv.runtime}
                view_mode={@view_mode}
                turns={@turns_by_id}
              />
            <% end %>
            <div :if={@events == []} class="text-zinc-500">Waiting for output…</div>
          </div>
      <% end %>

      <div
        :if={!@subscription_active}
        class="bg-amber-50 border border-amber-200 rounded px-4 py-3 text-sm text-amber-900"
      >
        <span class="font-medium">Read-only:</span>
        your subscription is inactive, so you can view this conversation and stop
        running work but not send prompts.
        <.link navigate={~p"/account/billing"} class="underline font-medium">
          Update billing
        </.link>
      </div>

      <form
        :if={@subscription_active}
        phx-submit="send_prompt"
        phx-change="update_prompt"
        class="bg-white rounded shadow border border-zinc-200 p-4 space-y-3"
      >
        <.input
          id="prompt"
          name="prompt"
          type="textarea"
          rows="3"
          value={@prompt}
          placeholder="Send another prompt…"
          phx-hook="SubmitOnCmdEnter"
        />
        <div :if={@pending_images != []} class="flex flex-wrap gap-2">
          <%= for img <- @pending_images do %>
            <div class="relative group">
              <img
                src={img["url"]}
                class="h-16 w-16 object-cover rounded border border-zinc-200 cursor-pointer"
                onclick={"window.open('#{img["url"]}', '_blank')"}
              />
              <span class="absolute -top-1 -right-1 hidden group-hover:flex bg-zinc-800 text-white text-[9px] rounded px-1">
                {img["name"]}
              </span>
            </div>
          <% end %>
        </div>
        <div class="flex justify-between items-center gap-3">
          <label class="cursor-pointer flex items-center gap-1 text-xs text-zinc-500 hover:text-zinc-700">
            <svg
              xmlns="http://www.w3.org/2000/svg"
              class="h-4 w-4"
              fill="none"
              viewBox="0 0 24 24"
              stroke="currentColor"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 14m-6-6h.01M6 20h12a2 2 0 002-2V6a2 2 0 00-2 2v12a2 2 0 002 2z"
              />
            </svg>
            <span>
              {if @pending_images == [],
                do: "Attach images",
                else: "#{length(@pending_images)} image(s)"}
            </span>
            <input
              type="file"
              accept="image/png,image/jpeg,image/gif,image/webp"
              multiple
              class="hidden"
              id="image-picker"
              phx-hook="ImagePicker"
            />
          </label>
          <div class="flex items-center gap-3">
            <span class="text-xs text-zinc-400">
              <kbd
                class="px-1 py-0.5 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono"
                phx-no-format
              >&#8984;</kbd>
              <kbd
                class="px-1 py-0.5 bg-zinc-100 border border-zinc-200 rounded text-[10px] font-mono"
                phx-no-format
              >Enter</kbd> to send
            </span>
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
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium bg-blue-100 text-blue-700">
      ui
    </span>
    """
  end

  defp source_badge(%{source: "agent"} = assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium bg-amber-100 text-amber-700">
      agent
    </span>
    """
  end

  defp source_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center rounded px-1.5 py-0.5 text-xs font-medium bg-zinc-100 text-zinc-600">
      {@source}
    </span>
    """
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
    <.event_line event={@node.event} runtime={@runtime} view_mode={@view_mode} />
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
    <details
      id={"section-#{@node.started.id}"}
      open={@open?}
      data-force-open={to_string(@open?)}
      phx-hook="KeepOpen"
      class="group"
    >
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
                <.block_row block={block} stream="stdout" />
              <% end %>
            </div>
          <% _ -> %>
            <div class="space-y-1">
              <%= for child <- @node.children do %>
                <.tree_node node={child} runtime={@runtime} view_mode={@view_mode} turns={@turns} />
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
        <span :if={@block[:result] && @block.result.error?} class="text-rose-300 text-[10px] shrink-0">
          error
        </span>
        <span
          :if={@block[:result] && not @block.result.error?}
          class="text-emerald-400 text-[10px] shrink-0"
        >
          &#10003;
        </span>
      </summary>
      <div class="mt-1 space-y-1">
        <div class="text-zinc-500 text-[10px] uppercase tracking-wider">input</div>
        <pre class="text-zinc-300 whitespace-pre-wrap text-xs">{@block.body}</pre>
        <div :if={@block[:result]} class="text-zinc-500 text-[10px] uppercase tracking-wider mt-1">
          result
        </div>
        <pre
          :if={@block[:result]}
          class={[
            "whitespace-pre-wrap text-xs",
            if(@block.result.error?, do: "text-rose-300", else: "text-zinc-300")
          ]}
        >{@block.result.body}</pre>
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

  defp truncate(s, n) when is_binary(s) and byte_size(s) > n,
    do: binary_part(s, 0, n) <> "…"

  defp truncate(s, _), do: s

  # ── stage row helpers ───────────────────────────────────────────────────────

  defp send_decoded_prompt(socket, p, decoded_images) do
    case ConversationServer.send_prompt(
           socket.assigns.conv.id,
           p,
           decoded_images,
           FountainWeb.Audited.attribution(socket)
         ) do
      :ok ->
        # Refetch the conversation — wake-from-cold flips sandbox + status.
        conv =
          Conversations.get_conversation!(socket.assigns.conv.id, socket.assigns.current_user.id)

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

      # The on_mount hook gates at mount only, so a socket that connected
      # while the subscription was active survives a mid-session lapse (#401).
      # Same handling ConversationsLive.New already has.
      {:error, :subscription_required} ->
        {:noreply,
         socket
         |> put_flash(:error, "An active subscription is required to send a prompt.")
         |> push_navigate(to: ~p"/account/billing")}

      {:error, {:sandbox_quota_exceeded, %{count: count, limit: limit}}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "You have #{count} of #{limit} concurrent sandboxes in use. " <>
             "Terminate a conversation before starting another."
         )}

      {:error, :provisioning} ->
        {:noreply,
         put_flash(socket, :error, "The conversation is still provisioning — try again shortly.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Couldn't send: #{inspect(reason)}")}
    end
  end

  defp stage_icon("provision"), do: "&#10024;"
  defp stage_icon("checkpoint_restore"), do: "&#128230;"
  defp stage_icon("setup"), do: "&#128736;"
  defp stage_icon("packages"), do: "&#128280;"
  defp stage_icon("network"), do: "&#127760;"
  defp stage_icon("clone"), do: "&#129319;"
  defp stage_icon("turn"), do: "&#128172;"
  defp stage_icon("reattach"), do: "&#128268;"
  defp stage_icon("sandbox"), do: "&#128164;"
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
