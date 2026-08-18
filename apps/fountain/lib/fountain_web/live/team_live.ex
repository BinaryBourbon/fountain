defmodule FountainWeb.TeamLive do
  @moduledoc """
  The team page: agents as teammates, one persistent conversation each,
  laid out like a messaging app — the roster on the left, the selected
  teammate's conversation on the right.

  Everything here is a view over `Fountain.Team`: a teammate *is* a
  conversation bound to the team channel, and its sandbox is the teammate's
  computer. Adding a teammate opens that conversation (and boots the
  computer); a message is a turn on it; removing terminates and unbinds.
  The transcript renders through `ConversationsLive.Chat`, the same bubbles
  `/conversations/:id` shows in chat mode.

  Live updates ride the per-conversation `conv:<id>` topics of every
  teammate: the selected one streams into the transcript, the others bump
  their row's activity so the unread dot and ordering stay honest.
  """
  use FountainWeb, :live_view

  import FountainWeb.ConversationsLive.Chat,
    only: [chat_view: 1, chat_assistant_reply: 2, agent_glyph: 1]

  alias Fountain.{Conversations, Team}
  alias Fountain.Conversations.{ConversationServer, LogEvent}

  @impl true
  def mount(params, _session, socket) do
    user_id = socket.assigns.current_user.id
    teammates = load_teammates(user_id)

    if connected?(socket) do
      Enum.each(teammates, &subscribe_teammate/1)
    end

    socket =
      socket
      |> assign(:page_title, "Team")
      |> assign(:user_id, user_id)
      |> assign(:teammates, teammates)
      |> assign(:addable_agents, Team.list_addable_agents(user_id))
      |> assign(:selected, nil)
      |> assign(:events, [])
      |> assign(:turns_by_id, %{})
      |> assign(:prompt, "")
      |> assign(:picker_open, false)

    # `/team` with no teammate named lands on the most recently active one,
    # the way a messaging app opens on the top thread; `/team/:agent_id` is
    # handled in handle_params. An empty team shows the invite.
    socket =
      case {params, teammates} do
        {%{"agent_id" => _}, _} -> socket
        {_, [first | _]} -> select_teammate(socket, first)
        _ -> socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"agent_id" => agent_id}, _uri, socket) do
    case Enum.find(socket.assigns.teammates, &(&1.agent.id == agent_id)) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That agent is not on your team")
         |> push_patch(to: ~p"/team")}

      teammate ->
        {:noreply, select_teammate(socket, teammate)}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp select_teammate(socket, %{conversation: conv} = teammate) do
    user_id = socket.assigns.user_id
    if connected?(socket), do: Conversations.mark_read(conv.id, user_id)

    # Ownership: established by the tenant-scoped Team.list_teammates in
    # mount, which is where `teammate` came from.
    events = Conversations._unsafe_list_log_events(conv.id)

    socket
    |> assign(:selected, teammate)
    |> assign(:events, events)
    |> assign(:turns_by_id, load_turns(conv.id))
    |> assign(:prompt, "")
    |> assign(:teammates, mark_read_locally(socket.assigns.teammates, conv.id))
    |> assign(:page_title, "#{teammate.agent.name} · Team")
  end

  defp load_turns(conv_id) do
    # Ownership: only called after the scoped list in mount / add.
    Conversations._unsafe_list_turns(conv_id)
    |> Enum.map(&Map.put(&1, :image_count, length(&1.images || [])))
    |> Map.new(&{&1.id, &1})
  end

  # The roster with each row's preview text attached. Previews read the last
  # turn's events (one query per teammate) — cheap for a team-sized list, and
  # only recomputed on stage events, not per output chunk.
  defp load_teammates(user_id) do
    user_id
    |> Team.list_teammates()
    |> Enum.map(&Map.put(&1, :preview, preview_for(&1)))
  end

  defp preview_for(%{last_turn: nil}), do: nil

  defp preview_for(%{last_turn: %{status: status}}) when status in ["pending", "running"],
    do: :typing

  defp preview_for(%{last_turn: turn, conversation: conv}) do
    # Ownership: `turn` belongs to a conversation from the scoped listing.
    reply =
      turn.id
      |> Conversations._unsafe_list_turn_log_events()
      |> chat_assistant_reply(conv.runtime)

    if reply == "", do: {:you, turn.prompt}, else: {:them, reply}
  end

  defp subscribe_teammate(%{conversation: conv}) do
    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
  end

  # ── live updates ────────────────────────────────────────────────────────────

  @impl true
  def handle_info({:log_event, %LogEvent{} = ev}, socket) do
    selected = socket.assigns.selected

    socket =
      if selected && ev.conversation_id == selected.conversation.id do
        apply_selected_event(socket, ev)
      else
        socket
      end

    # Stage events are when the roster's facts change (a turn opened or
    # closed, a sandbox came or went); output only means "something new" —
    # bump that row's activity locally instead of re-querying per chunk.
    socket =
      cond do
        ev.kind == "stage" -> refresh_teammates(socket)
        ev.kind == "output" -> bump_activity(socket, ev)
        true -> socket
      end

    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp apply_selected_event(socket, ev) do
    if ev.id > last_event_id(socket.assigns.events) do
      conv_id = socket.assigns.selected.conversation.id

      turns_by_id =
        if ev.kind == "stage" and ev.stage == "turn" and ev.state == "started",
          do: load_turns(conv_id),
          else: socket.assigns.turns_by_id

      # A turn closing is when the reply is complete: that is the moment
      # "read" means something. Marking per output chunk would broadcast a
      # sidebar refresh on every token.
      if ev.kind == "stage" and ev.stage == "turn" and ev.state != "started" do
        Conversations.mark_read(conv_id, socket.assigns.user_id)
      end

      socket
      |> assign(:events, socket.assigns.events ++ [ev])
      |> assign(:turns_by_id, turns_by_id)
    else
      socket
    end
  end

  defp last_event_id([]), do: 0
  defp last_event_id(events), do: events |> List.last() |> Map.get(:id, 0)

  defp refresh_teammates(socket) do
    teammates = load_teammates(socket.assigns.user_id)

    selected =
      case socket.assigns.selected do
        nil -> nil
        %{agent: %{id: id}} -> Enum.find(teammates, &(&1.agent.id == id))
      end

    socket
    |> assign(:teammates, teammates)
    |> assign(:selected, selected || socket.assigns.selected)
  end

  defp bump_activity(socket, ev) do
    teammates =
      Enum.map(socket.assigns.teammates, fn
        %{conversation: %{id: id} = conv} = t when id == ev.conversation_id ->
          conv = %{conv | last_active_at: ev.inserted_at}
          conv = if selected?(socket, id), do: %{conv | last_read_at: ev.inserted_at}, else: conv
          %{t | conversation: conv, preview: :typing}

        t ->
          t
      end)
      |> Enum.sort_by(& &1.conversation.last_active_at, {:desc, DateTime})

    assign(socket, :teammates, teammates)
  end

  defp selected?(%{assigns: %{selected: %{conversation: %{id: id}}}}, id), do: true
  defp selected?(_socket, _id), do: false

  # The selected thread is being read right now: keep its dot off between
  # the `mark_read` writes without a query.
  defp mark_read_locally(teammates, conv_id) do
    now = DateTime.utc_now()

    Enum.map(teammates, fn
      %{conversation: %{id: ^conv_id} = conv} = t ->
        %{t | conversation: %{conv | last_read_at: now}}

      t ->
        t
    end)
  end

  # ── events ──────────────────────────────────────────────────────────────────

  # Read-only for a lapsed subscription (#505, ADR 0006): viewing stays open,
  # the events that create spend do not. Interrupt and remove still work —
  # they stop spend.
  @spend_events ~w(send update_prompt add_teammate open_picker)

  @impl true
  def handle_event(event, _params, %{assigns: %{subscription_active: false}} = socket)
      when event in @spend_events do
    {:noreply,
     put_flash(
       socket,
       :error,
       "Your subscription is inactive — the team is read-only. Update billing to message or add teammates."
     )}
  end

  def handle_event("open_picker", _, socket) do
    {:noreply,
     socket
     |> assign(:addable_agents, Team.list_addable_agents(socket.assigns.user_id))
     |> assign(:picker_open, true)}
  end

  def handle_event("close_picker", _, socket), do: {:noreply, assign(socket, :picker_open, false)}

  def handle_event("add_teammate", %{"agent_id" => agent_id}, socket) do
    user_id = socket.assigns.user_id

    case Team.add_teammate(user_id, agent_id, FountainWeb.Audited.attribution(socket)) do
      {:ok, conv} ->
        Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

        {:noreply,
         socket
         |> assign(:picker_open, false)
         |> assign(:teammates, load_teammates(user_id))
         |> assign(:addable_agents, Team.list_addable_agents(user_id))
         |> push_patch(to: ~p"/team/#{agent_id}")}

      {:error, reason} ->
        {:noreply, socket |> assign(:picker_open, false) |> flash_error(reason)}
    end
  end

  def handle_event("remove_teammate", %{"agent_id" => agent_id}, socket) do
    user_id = socket.assigns.user_id
    _ = Team.remove_teammate(user_id, agent_id, FountainWeb.Audited.attribution(socket))

    still_selected? =
      case socket.assigns.selected do
        %{agent: %{id: ^agent_id}} -> false
        nil -> false
        _ -> true
      end

    socket =
      socket
      |> assign(:teammates, load_teammates(user_id))
      |> assign(:addable_agents, Team.list_addable_agents(user_id))
      |> put_flash(:info, "Removed from the team")

    if still_selected?,
      do: {:noreply, socket},
      else:
        {:noreply,
         socket
         |> assign(:selected, nil)
         |> assign(:events, [])
         |> assign(:turns_by_id, %{})
         |> push_patch(to: ~p"/team")}
  end

  # Mobile: back from the thread to the roster.
  def handle_event("deselect", _, socket) do
    {:noreply,
     socket
     |> assign(:selected, nil)
     |> assign(:events, [])
     |> assign(:turns_by_id, %{})
     |> push_patch(to: ~p"/team")}
  end

  def handle_event("update_prompt", %{"prompt" => p}, socket) do
    {:noreply, assign(socket, :prompt, p)}
  end

  def handle_event("send", %{"prompt" => p}, %{assigns: %{selected: %{} = selected}} = socket)
      when byte_size(p) > 0 do
    text = String.trim(p)

    if text == "" do
      {:noreply, socket}
    else
      send_message(socket, selected, text)
    end
  end

  def handle_event("send", _, socket), do: {:noreply, socket}

  def handle_event("interrupt", _, %{assigns: %{selected: %{conversation: conv}}} = socket) do
    case ConversationServer.interrupt(conv.id, FountainWeb.Audited.attribution(socket)) do
      :ok -> {:noreply, put_flash(socket, :info, "Interrupted")}
      {:error, :idle} -> {:noreply, put_flash(socket, :error, "No turn is running")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Nothing is running")}
    end
  end

  def handle_event("interrupt", _, socket), do: {:noreply, socket}

  defp send_message(socket, selected, text) do
    user_id = socket.assigns.user_id
    agent_id = selected.agent.id

    case Team.send_message(user_id, agent_id, text, [], FountainWeb.Audited.attribution(socket)) do
      {:ok, conv} ->
        # A fresh conversation (the old computer was gone) is a new topic to
        # follow and a new transcript to show; the same one just needs its
        # header facts refreshed.
        socket =
          if conv.id == selected.conversation.id do
            socket
            |> assign(:prompt, "")
            |> push_event("clear_composer", %{})
            |> refresh_teammates()
          else
            Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
            socket = refresh_teammates(socket)

            case Enum.find(socket.assigns.teammates, &(&1.agent.id == agent_id)) do
              nil -> assign(socket, :prompt, "")
              teammate -> select_teammate(socket, teammate)
            end
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, flash_error(socket, reason)}
    end
  end

  defp flash_error(socket, :busy),
    do: put_flash(socket, :error, "They're still working on the last message")

  defp flash_error(socket, :provisioning),
    do: put_flash(socket, :error, "Their computer is still starting — try again shortly")

  defp flash_error(socket, :not_found), do: put_flash(socket, :error, "Agent not found")

  defp flash_error(socket, :subscription_required) do
    socket
    |> put_flash(:error, "An active subscription is required.")
    |> push_navigate(to: ~p"/account/billing")
  end

  defp flash_error(socket, {:sandbox_quota_exceeded, %{count: count, limit: limit}}) do
    put_flash(
      socket,
      :error,
      "You have #{count} of #{limit} concurrent sandboxes in use. " <>
        "Remove a teammate or terminate a conversation first."
    )
  end

  defp flash_error(socket, reason), do: put_flash(socket, :error, "Failed: #{inspect(reason)}")

  # ── presence ────────────────────────────────────────────────────────────────

  # What the teammate's computer is doing, from the conversation and sandbox
  # rows. `{label, dot_class}`.
  defp presence(%{status: "running"}), do: {"working", "bg-emerald-500 animate-pulse"}
  defp presence(%{status: "pending"}), do: {"starting computer", "bg-amber-400 animate-pulse"}

  defp presence(%{status: "idle", sandbox: %{status: s}}) when s in ["ready", "starting"],
    do: {"online", "bg-emerald-500"}

  defp presence(%{status: "idle", sandbox: %{status: "suspended"}}),
    do: {"asleep · wakes on message", "bg-zinc-400"}

  defp presence(%{status: "idle"}), do: {"away · wakes on message", "bg-zinc-400"}
  defp presence(%{status: "failed"}), do: {"offline · failed", "bg-rose-500"}
  defp presence(_), do: {"offline · new computer on message", "bg-zinc-300"}

  defp avatar_url(%{id: id, avatar_media_type: mt}) when is_binary(mt), do: "/agents/#{id}/avatar"
  defp avatar_url(_), do: nil

  defp initials(name) when is_binary(name) do
    name
    |> String.split(~r/[\s_-]+/, trim: true)
    |> Enum.take(2)
    |> Enum.map_join(&String.first/1)
    |> String.upcase()
  end

  defp initials(_), do: "?"

  defp format_time(%DateTime{} = dt) do
    now = DateTime.utc_now()

    if DateTime.to_date(dt) == DateTime.to_date(now),
      do: Calendar.strftime(dt, "%H:%M"),
      else: Calendar.strftime(dt, "%b %-d")
  end

  defp format_time(_), do: ""

  # ── render ──────────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div class="-m-6 flex h-[calc(100vh-49px)] md:h-screen bg-[var(--color-bg-0)] text-[var(--color-text-primary)]">
      <%!-- Roster --%>
      <aside class={[
        "w-full sm:w-80 shrink-0 flex-col border-r border-[var(--color-border)] bg-[var(--color-bg-1)]",
        if(@selected, do: "hidden sm:flex", else: "flex")
      ]}>
        <div class="flex items-center justify-between px-4 py-3 border-b border-[var(--color-border)]">
          <h1 class="text-lg font-semibold">Team</h1>
          <button
            id="add-teammate-button"
            type="button"
            phx-click="open_picker"
            class="size-8 rounded-full flex items-center justify-center text-lg leading-none bg-[var(--color-brand)] text-white hover:bg-[var(--color-brand-hover)] transition-colors"
            aria-label="Add a teammate"
            title="Add a teammate"
          >
            +
          </button>
        </div>

        <div class="flex-1 min-h-0 overflow-y-auto">
          <div
            :if={@teammates == []}
            class="p-6 text-sm text-[var(--color-text-secondary)] space-y-3"
          >
            <p>No one on the team yet.</p>
            <p>
              Add an agent and it gets its own computer and one ongoing conversation with you —
              like a coworker in your messages.
            </p>
            <button
              type="button"
              phx-click="open_picker"
              class="rounded-md px-3 py-1.5 text-sm font-medium bg-[var(--color-brand)] text-white hover:bg-[var(--color-brand-hover)]"
            >
              Add a teammate
            </button>
          </div>

          <ul id="team-roster" role="list">
            <li :for={t <- @teammates} id={"teammate-#{t.agent.id}"}>
              <.roster_row teammate={t} selected={!!(@selected && @selected.agent.id == t.agent.id)} />
            </li>
          </ul>
        </div>
      </aside>

      <%!-- Thread --%>
      <section class={[
        "flex-1 min-w-0 flex-col",
        if(@selected, do: "flex", else: "hidden sm:flex")
      ]}>
        <div
          :if={is_nil(@selected)}
          class="flex-1 flex items-center justify-center text-sm text-[var(--color-text-muted)]"
        >
          <span :if={@teammates != []}>Pick a teammate to open the conversation.</span>
          <span :if={@teammates == []}>Your team's conversations will show here.</span>
        </div>

        <%= if @selected do %>
          <.thread_header teammate={@selected} />

          <div
            id={"team-thread-#{@selected.conversation.id}"}
            phx-hook="ScrollBottom"
            class="flex-1 min-h-0 overflow-y-auto px-6 py-6 bg-gradient-to-b from-zinc-50 to-white"
          >
            <.chat_view turns={@turns_by_id} events={@events} conv={@selected.conversation} />
            <div
              :if={map_size(@turns_by_id) == 0}
              class="h-full flex flex-col items-center justify-center text-center gap-2 text-zinc-400"
            >
              <div class="text-3xl">{agent_glyph(@selected.conversation.runtime)}</div>
              <div class="text-sm">
                <%= case @selected.conversation.status do %>
                  <% "pending" -> %>
                    Starting <span class="font-medium text-zinc-600">{@selected.agent.name}</span>'s
                    computer&hellip;
                  <% "failed" -> %>
                    <span class="font-medium text-zinc-600">{@selected.agent.name}</span>'s computer
                    failed to start — a message tries a new one.
                  <% _ -> %>
                    Say hello to <span class="font-medium text-zinc-600">{@selected.agent.name}</span>.
                <% end %>
              </div>
              <div class="text-xs">
                {@selected.agent.runtime} &middot; {@selected.agent.model}
              </div>
            </div>
          </div>

          <div
            :if={!@subscription_active}
            class="border-t border-amber-200 bg-amber-50 px-6 py-3 text-sm text-amber-900"
          >
            <span class="font-medium">Read-only:</span>
            your subscription is inactive.
            <.link navigate={~p"/account/billing"} class="underline font-medium">
              Update billing
            </.link>
          </div>

          <form
            :if={@subscription_active}
            id="team-composer"
            phx-submit="send"
            phx-change="update_prompt"
            class="border-t border-[var(--color-border)] bg-[var(--color-bg-1)] px-4 py-3 flex items-end gap-2"
          >
            <textarea
              id={"team-prompt-#{@selected.conversation.id}"}
              name="prompt"
              rows="1"
              placeholder={"Message #{@selected.agent.name}…"}
              phx-hook="SubmitOnEnter"
              autofocus
              class="flex-1 resize-none rounded-2xl border border-[var(--color-border)] bg-[var(--color-bg-0)] px-4 py-2 text-sm leading-6 max-h-40 focus:outline-none focus:ring-2 focus:ring-[var(--color-focus-ring)]"
            >{@prompt}</textarea>
            <button
              type="submit"
              phx-disable-with="…"
              class="size-9 shrink-0 rounded-full flex items-center justify-center bg-blue-600 text-white hover:bg-blue-500 disabled:opacity-50"
              aria-label="Send"
              title="Send (Enter · Shift+Enter for a new line)"
            >
              <svg class="size-4" viewBox="0 0 20 20" fill="currentColor" aria-hidden="true">
                <path d="M10 3a.75.75 0 0 1 .53.22l5 5a.75.75 0 1 1-1.06 1.06l-3.72-3.72V16.5a.75.75 0 0 1-1.5 0V5.56L5.53 9.28a.75.75 0 0 1-1.06-1.06l5-5A.75.75 0 0 1 10 3Z" />
              </svg>
            </button>
          </form>
        <% end %>
      </section>

      <.agent_picker :if={@picker_open} agents={@addable_agents} />
    </div>
    """
  end

  attr :teammate, :map, required: true
  attr :selected, :boolean, default: false

  defp roster_row(assigns) do
    conv = assigns.teammate.conversation
    {label, dot} = presence(conv)

    assigns =
      assign(assigns,
        conv: conv,
        presence_label: label,
        dot: dot,
        unread: !assigns.selected and Conversations.unread?(conv),
        avatar_url: avatar_url(assigns.teammate.agent)
      )

    ~H"""
    <.link
      patch={~p"/team/#{@teammate.agent.id}"}
      class={[
        "flex items-center gap-3 px-4 py-3 border-b border-[var(--color-border)] transition-colors",
        @selected && "bg-blue-600 text-white",
        !@selected && "hover:bg-[var(--color-bg-2)]"
      ]}
    >
      <div class="relative shrink-0">
        <div class="size-11 rounded-full overflow-hidden flex items-center justify-center text-sm font-semibold bg-zinc-200 text-zinc-700">
          <img :if={@avatar_url} src={@avatar_url} class="w-full h-full object-cover" alt="" />
          <span :if={is_nil(@avatar_url)}>{initials(@teammate.agent.name)}</span>
        </div>
        <span
          class={["absolute bottom-0 right-0 size-3 rounded-full ring-2 ring-white", @dot]}
          title={@presence_label}
        />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline justify-between gap-2">
          <span class="font-medium truncate">{@teammate.agent.name}</span>
          <span class={[
            "text-[11px] shrink-0",
            @selected && "text-blue-100",
            !@selected && "text-[var(--color-text-muted)]"
          ]}>
            {format_time(@conv.last_active_at)}
          </span>
        </div>
        <div class="flex items-center gap-2">
          <span class={[
            "text-xs truncate flex-1",
            @selected && "text-blue-100",
            !@selected && "text-[var(--color-text-secondary)]",
            @unread && !@selected && "font-medium text-[var(--color-text-primary)]"
          ]}>
            <.preview preview={@teammate.preview} />
          </span>
          <span :if={@unread} class="size-2 rounded-full bg-blue-600 shrink-0" title="Unread" />
        </div>
      </div>
    </.link>
    """
  end

  attr :preview, :any, required: true

  defp preview(%{preview: nil} = assigns), do: ~H|<span class="italic">No messages yet</span>|
  defp preview(%{preview: :typing} = assigns), do: ~H|<span class="italic">typing…</span>|

  defp preview(%{preview: {who, text}} = assigns) do
    assigns = assign(assigns, who: who, text: text)

    ~H"""
    <span :if={@who == :you}>You: </span>{@text}
    """
  end

  attr :teammate, :map, required: true

  defp thread_header(assigns) do
    conv = assigns.teammate.conversation
    {label, dot} = presence(conv)
    assigns = assign(assigns, conv: conv, presence_label: label, dot: dot)

    ~H"""
    <header class="flex items-center justify-between gap-3 px-6 py-3 border-b border-[var(--color-border)] bg-[var(--color-bg-1)]">
      <button
        type="button"
        phx-click="deselect"
        class="sm:hidden shrink-0 rounded-md px-2 py-1 text-sm text-blue-600"
        aria-label="Back to the team"
      >
        &lsaquo; Team
      </button>
      <div class="min-w-0 flex-1">
        <div class="font-semibold truncate">{@teammate.agent.name}</div>
        <div class="flex items-center gap-1.5 text-xs text-[var(--color-text-secondary)] whitespace-nowrap min-w-0">
          <span class={["size-2 rounded-full shrink-0", @dot]} />
          <span class="truncate">{@presence_label}</span>
          <span
            :if={@conv.sandbox}
            class="hidden md:inline text-[var(--color-text-muted)] font-mono truncate"
          >
            &middot; {@conv.sandbox.provider}/{@conv.sandbox.sprite_name}
          </span>
        </div>
      </div>
      <div class="flex items-center gap-2 shrink-0 text-xs">
        <button
          :if={@conv.status == "running"}
          type="button"
          phx-click="interrupt"
          class="rounded-md border border-[var(--color-border)] px-2.5 py-1 hover:bg-[var(--color-bg-2)]"
        >
          Interrupt
        </button>
        <.link
          navigate={~p"/conversations/#{@conv.id}"}
          class="hidden sm:inline rounded-md border border-[var(--color-border)] px-2.5 py-1 hover:bg-[var(--color-bg-2)]"
          title="The full conversation view: stages, tool calls, raw output"
        >
          Details
        </.link>
        <button
          type="button"
          phx-click="remove_teammate"
          phx-value-agent_id={@teammate.agent.id}
          data-confirm={"Remove #{@teammate.agent.name} from the team? Their computer is shut down; the conversation stays in your history."}
          class="rounded-md border border-rose-200 text-rose-700 px-2.5 py-1 hover:bg-rose-50"
        >
          Remove
        </button>
      </div>
    </header>
    """
  end

  attr :agents, :list, required: true

  defp agent_picker(assigns) do
    ~H"""
    <div id="add-teammate" class="relative z-50">
      <div
        class="fixed inset-0 bg-black/50 backdrop-blur-sm"
        phx-click="close_picker"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto flex items-center justify-center p-4"
        role="dialog"
        aria-modal="true"
        aria-labelledby="add-teammate-title"
        phx-window-keydown="close_picker"
        phx-key="escape"
      >
        <div class="relative w-full max-w-md rounded-xl shadow-xl bg-[var(--color-bg-1)] border border-[var(--color-border)]">
          <div class="flex items-center justify-between px-6 py-4 border-b border-[var(--color-border)]">
            <h2 id="add-teammate-title" class="text-base font-semibold">Add a teammate</h2>
            <button
              type="button"
              phx-click="close_picker"
              aria-label="Close"
              class="rounded p-1 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
            >
              &times;
            </button>
          </div>
          <div class="px-6 py-4 text-sm">
            <p class="text-[var(--color-text-secondary)] mb-3">
              Each teammate gets its own computer and one ongoing conversation with you.
            </p>
            <div :if={@agents == []} class="text-[var(--color-text-muted)] italic">
              Every agent you have is already on the team.
              <.link navigate={~p"/agents/new"} class="underline not-italic">Create another</.link>
            </div>
            <ul :if={@agents != []} class="divide-y divide-[var(--color-border)]" role="list">
              <li :for={a <- @agents} class="py-2 flex items-center justify-between gap-3">
                <div class="min-w-0">
                  <div class="font-medium truncate">{a.name}</div>
                  <div class="text-xs text-[var(--color-text-muted)] truncate">
                    {a.runtime} &middot; {a.model}
                  </div>
                </div>
                <button
                  type="button"
                  phx-click="add_teammate"
                  phx-value-agent_id={a.id}
                  phx-disable-with="Adding…"
                  class="shrink-0 rounded-md px-3 py-1 text-xs font-medium bg-[var(--color-brand)] text-white hover:bg-[var(--color-brand-hover)]"
                >
                  Add
                </button>
              </li>
            </ul>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
