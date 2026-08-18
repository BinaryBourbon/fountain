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

  import FountainWeb.ConversationsLive.Chat, only: [chat_view: 1, agent_glyph: 1]
  alias FountainWeb.TeamPresenter

  alias Fountain.{Conversations, Team}
  alias Fountain.Conversations.{ConversationServer, LogEvent}
  alias Fountain.Team.{Schedule, Schedules}

  @empty_add_form %{"agent_id" => nil, "name" => "", "environment_id" => "", "vault_id" => ""}

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
      |> assign(:add_form, @empty_add_form)
      |> assign(:add_options, %{environments: [], vaults: []})
      |> assign(:schedules_open, false)
      |> assign(:schedules, [])
      |> assign(:schedule_form, nil)
      |> assign(:editing_schedule, nil)

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
    |> assign(:page_title, "#{teammate.name} · Team")
    |> assign(:schedules, Schedules.list_schedules(user_id, teammate.agent.id))
    |> assign(:schedules_open, false)
    |> assign(:schedule_form, nil)
    |> assign(:editing_schedule, nil)
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
    |> Enum.map(&Map.put(&1, :preview, TeamPresenter.preview(&1)))
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
  @spend_events ~w(send update_prompt add_teammate open_picker run_schedule)

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
    agents = Team.list_addable_agents(socket.assigns.user_id)
    first = List.first(agents)

    {:noreply,
     socket
     |> assign(:addable_agents, agents)
     |> assign(:picker_open, true)
     |> set_add_form(%{@empty_add_form | "agent_id" => first && first.id})}
  end

  def handle_event("close_picker", _, socket), do: {:noreply, assign(socket, :picker_open, false)}

  # The picker form as it is typed into. A change of agent re-derives the
  # environment and vault choices from that agent's allowlists.
  def handle_event("validate_add", %{"add" => params}, socket) do
    {:noreply, set_add_form(socket, Map.merge(socket.assigns.add_form, params))}
  end

  def handle_event("add_teammate", %{"add" => %{"agent_id" => agent_id} = params}, socket)
      when is_binary(agent_id) and agent_id != "" do
    user_id = socket.assigns.user_id
    attrs = Map.take(params, ["name", "environment_id", "vault_id"])

    case Team.add_teammate(user_id, agent_id, attrs, FountainWeb.Audited.attribution(socket)) do
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

  def handle_event("add_teammate", _params, socket), do: {:noreply, socket}

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
  # ── schedules: a cron that runs this teammate with a prompt ────────────────

  def handle_event("open_schedules", _, %{assigns: %{selected: %{} = selected}} = socket) do
    {:noreply,
     socket
     |> assign(:schedules, Schedules.list_schedules(socket.assigns.user_id, selected.agent.id))
     |> assign(:schedules_open, true)
     |> assign(:editing_schedule, nil)
     |> assign(:schedule_form, new_schedule_form())}
  end

  def handle_event("open_schedules", _, socket), do: {:noreply, socket}

  def handle_event("close_schedules", _, socket) do
    {:noreply,
     socket
     |> assign(:schedules_open, false)
     |> assign(:editing_schedule, nil)
     |> assign(:schedule_form, nil)}
  end

  def handle_event("validate_schedule", %{"schedule" => params}, socket) do
    base = socket.assigns.editing_schedule || %Schedule{}
    changeset = base |> Schedule.changeset(params) |> Map.put(:action, :validate)
    {:noreply, assign(socket, :schedule_form, to_form(changeset, as: :schedule))}
  end

  def handle_event("save_schedule", %{"schedule" => params}, socket) do
    %{user_id: user_id, selected: selected} = socket.assigns
    attribution = FountainWeb.Audited.attribution(socket)

    result =
      case socket.assigns.editing_schedule do
        nil ->
          Schedules.create_schedule(
            user_id,
            Map.put(params, "agent_id", selected.agent.id),
            attribution
          )

        %Schedule{} = schedule ->
          Schedules.update_schedule(schedule, params, attribution)
      end

    case result do
      {:ok, _schedule} ->
        {:noreply,
         socket
         |> assign(:schedules, Schedules.list_schedules(user_id, selected.agent.id))
         |> assign(:editing_schedule, nil)
         |> assign(:schedule_form, new_schedule_form())
         |> put_flash(:info, "Schedule saved")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, :schedule_form, to_form(changeset, as: :schedule))}

      {:error, reason} ->
        {:noreply, flash_error(socket, reason)}
    end
  end

  def handle_event("edit_schedule", %{"id" => id}, socket) do
    case Schedules.get_schedule(id, socket.assigns.user_id) do
      nil ->
        {:noreply, socket}

      schedule ->
        {:noreply,
         socket
         |> assign(:editing_schedule, schedule)
         |> assign(:schedule_form, to_form(Schedule.changeset(schedule, %{}), as: :schedule))}
    end
  end

  def handle_event("cancel_edit_schedule", _, socket) do
    {:noreply,
     socket
     |> assign(:editing_schedule, nil)
     |> assign(:schedule_form, new_schedule_form())}
  end

  def handle_event("toggle_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      Schedules.update_schedule(
        schedule,
        %{"enabled" => !schedule.enabled},
        FountainWeb.Audited.attribution(socket)
      )
    end)
  end

  def handle_event("delete_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      Schedules.delete_schedule(schedule, FountainWeb.Audited.attribution(socket))
    end)
  end

  def handle_event("run_schedule", %{"id" => id}, socket) do
    with_schedule(socket, id, fn schedule ->
      case Schedules.run_schedule(schedule, FountainWeb.Audited.attribution(socket)) do
        {:ok, conv} -> {:ok, conv}
        {:error, _} = err -> err
      end
    end)
  end

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

  # Keep the form and its option lists in step: the environment and vault
  # choices belong to the agent picked, and a pick that the new agent does not
  # offer falls back to the default (blank).
  defp set_add_form(socket, form) do
    agent = Enum.find(socket.assigns.addable_agents, &(&1.id == form["agent_id"]))

    options =
      if agent,
        do: Team.addable_options(socket.assigns.user_id, agent),
        else: %{environments: [], vaults: []}

    form =
      form
      |> Map.update("environment_id", "", &keep_if_offered(&1, options.environments))
      |> Map.update("vault_id", "", &keep_if_offered(&1, options.vaults))

    socket
    |> assign(:add_form, form)
    |> assign(:add_options, options)
  end

  defp keep_if_offered(id, offered) do
    if Enum.any?(offered, &(&1.id == id)), do: id, else: ""
  end

  defp new_schedule_form do
    to_form(Schedule.changeset(%Schedule{}, %{}), as: :schedule)
  end

  # Fetch the schedule tenant-scoped, act on it, refresh the list; the
  # teammate stays selected. A run that opened or fed a conversation also
  # refreshes the roster, since the thread may have a new turn or a new
  # computer.
  defp with_schedule(socket, id, fun) do
    %{user_id: user_id, selected: selected} = socket.assigns

    case Schedules.get_schedule(id, user_id) do
      nil ->
        {:noreply, socket}

      schedule ->
        socket =
          case fun.(schedule) do
            {:ok, %Fountain.Conversations.Conversation{} = conv} ->
              Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")

              socket
              |> put_flash(:info, "Sent — running now")
              |> refresh_teammates()
              |> reselect_after_run(conv)

            {:ok, _} ->
              socket

            {:error, reason} ->
              flash_error(socket, reason)
          end

        agent_id = (selected && selected.agent.id) || schedule.agent_id
        {:noreply, assign(socket, :schedules, Schedules.list_schedules(user_id, agent_id))}
    end
  end

  # A run into the teammate's thread may have replaced its computer; follow
  # the current conversation the way send_message does. A one-off run is
  # its own conversation and leaves the thread alone.
  defp reselect_after_run(socket, conv) do
    case socket.assigns.selected do
      %{agent: %{id: agent_id}, conversation: %{id: prev_id}} when prev_id != conv.id ->
        case Enum.find(socket.assigns.teammates, &(&1.agent.id == agent_id)) do
          %{conversation: %{id: ^prev_id}} -> socket
          nil -> socket
          teammate -> socket |> select_teammate(teammate) |> assign(:schedules_open, true)
        end

      _ ->
        socket
    end
  end

  defp flash_error(socket, :busy),
    do: put_flash(socket, :error, "They're still working on the last message")

  defp flash_error(socket, :provisioning),
    do: put_flash(socket, :error, "Their computer is still starting — try again shortly")

  defp flash_error(socket, :not_found), do: put_flash(socket, :error, "Agent not found")

  defp flash_error(socket, :environment_not_found),
    do: put_flash(socket, :error, "Environment not found")

  defp flash_error(socket, :environment_not_allowed),
    do: put_flash(socket, :error, "That agent may not use that environment")

  defp flash_error(socket, :vault_not_found), do: put_flash(socket, :error, "Vault not found")

  defp flash_error(socket, :vault_not_allowed),
    do: put_flash(socket, :error, "That agent may not use that vault")

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

  # The presence label and its dot, from the shared presenter's state.
  defp presence(conv) do
    %{state: state, label: label} = TeamPresenter.presence(conv)
    {label, presence_dot(state)}
  end

  defp presence_dot("working"), do: "bg-emerald-500 animate-pulse"
  defp presence_dot("starting"), do: "bg-amber-400 animate-pulse"
  defp presence_dot("online"), do: "bg-emerald-500"
  defp presence_dot("asleep"), do: "bg-zinc-400"
  defp presence_dot("away"), do: "bg-zinc-400"
  defp presence_dot("failed"), do: "bg-rose-500"
  defp presence_dot(_), do: "bg-zinc-300"

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
          <.thread_header teammate={@selected} schedule_count={length(@schedules)} />

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
                    Starting <span class="font-medium text-zinc-600">{@selected.name}</span>'s
                    computer&hellip;
                  <% "failed" -> %>
                    <span class="font-medium text-zinc-600">{@selected.name}</span>'s computer
                    failed to start — a message tries a new one.
                  <% _ -> %>
                    Say hello to <span class="font-medium text-zinc-600">{@selected.name}</span>.
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
              placeholder={"Message #{@selected.name}…"}
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

      <.agent_picker
        :if={@picker_open}
        agents={@addable_agents}
        form={@add_form}
        options={@add_options}
      />
      <.schedules_panel
        :if={@schedules_open && @selected}
        teammate={@selected}
        schedules={@schedules}
        form={@schedule_form}
        editing={@editing_schedule}
        subscription_active={@subscription_active}
      />
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
          <span :if={is_nil(@avatar_url)}>{initials(@teammate.name)}</span>
        </div>
        <span
          class={["absolute bottom-0 right-0 size-3 rounded-full ring-2 ring-white", @dot]}
          title={@presence_label}
        />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-baseline justify-between gap-2">
          <span class="font-medium truncate">{@teammate.name}</span>
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
  attr :schedule_count, :integer, default: 0

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
        <div class="font-semibold truncate">{@teammate.name}</div>
        <div class="flex items-center gap-1.5 text-xs text-[var(--color-text-secondary)] whitespace-nowrap min-w-0">
          <span :if={@teammate.name != @teammate.agent.name} class="truncate">
            {@teammate.agent.name} &middot;
          </span>
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
        <button
          id="open-schedules-button"
          type="button"
          phx-click="open_schedules"
          class="rounded-md border border-[var(--color-border)] px-2.5 py-1 hover:bg-[var(--color-bg-2)]"
          title="Scheduled prompts: run this teammate on a cron"
        >
          Schedules<span :if={@schedule_count > 0} class="ml-1 text-[var(--color-text-muted)]">{@schedule_count}</span>
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
          data-confirm={"Remove #{@teammate.name} from the team? Their computer is shut down; the conversation stays in your history."}
          class="rounded-md border border-rose-200 text-rose-700 px-2.5 py-1 hover:bg-rose-50"
        >
          Remove
        </button>
      </div>
    </header>
    """
  end

  attr :agents, :list, required: true
  attr :form, :map, required: true
  attr :options, :map, required: true

  defp agent_picker(assigns) do
    agent = Enum.find(assigns.agents, &(&1.id == assigns.form["agent_id"]))

    own_env =
      agent && agent.environment_id &&
        Enum.find(assigns.options.environments, &(&1.id == agent.environment_id))

    assigns =
      assign(assigns,
        agent: agent,
        own_env: own_env,
        # The agent's own environment is the blank pick, not a row of its own.
        other_envs:
          Enum.reject(assigns.options.environments, &(agent && &1.id == agent.environment_id))
      )

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
            <form
              :if={@agents != []}
              id="add-teammate-form"
              phx-change="validate_add"
              phx-submit="add_teammate"
              class="space-y-4"
            >
              <div class="space-y-1">
                <label
                  for="add-agent"
                  class="block text-xs font-medium text-[var(--color-text-secondary)]"
                >
                  Agent
                </label>
                <select
                  id="add-agent"
                  name="add[agent_id]"
                  class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-0)] px-3 py-2 text-sm"
                >
                  <option :for={a <- @agents} value={a.id} selected={@form["agent_id"] == a.id}>
                    {a.name} ({a.runtime} &middot; {a.model})
                  </option>
                </select>
              </div>

              <div class="space-y-1">
                <label
                  for="add-name"
                  class="block text-xs font-medium text-[var(--color-text-secondary)]"
                >
                  Name <span class="font-normal text-[var(--color-text-muted)]">(optional)</span>
                </label>
                <input
                  id="add-name"
                  type="text"
                  name="add[name]"
                  value={@form["name"]}
                  maxlength="120"
                  placeholder={(@agent && @agent.name) || "Teammate"}
                  autocomplete="off"
                  class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-0)] px-3 py-2 text-sm"
                />
                <p class="text-xs text-[var(--color-text-muted)]">
                  How they show up on the team. Blank uses the agent's name.
                </p>
              </div>

              <div :if={@other_envs != []} class="space-y-1">
                <label
                  for="add-environment"
                  class="block text-xs font-medium text-[var(--color-text-secondary)]"
                >
                  Environment
                </label>
                <select
                  id="add-environment"
                  name="add[environment_id]"
                  class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-0)] px-3 py-2 text-sm"
                >
                  <option value="" selected={@form["environment_id"] in [nil, ""]}>
                    <%= if @own_env do %>
                      Agent's default ({@own_env.name})
                    <% else %>
                      Agent's default
                    <% end %>
                  </option>
                  <option
                    :for={e <- @other_envs}
                    value={e.id}
                    selected={@form["environment_id"] == e.id}
                  >
                    {e.name}
                  </option>
                </select>
                <p class="text-xs text-[var(--color-text-muted)]">
                  Their computer is set up from this environment instead of the agent's own.
                </p>
              </div>

              <div :if={@options.vaults != []} class="space-y-1">
                <label
                  for="add-vault"
                  class="block text-xs font-medium text-[var(--color-text-secondary)]"
                >
                  Vault <span class="font-normal text-[var(--color-text-muted)]">(optional)</span>
                </label>
                <select
                  id="add-vault"
                  name="add[vault_id]"
                  class="w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-0)] px-3 py-2 text-sm"
                >
                  <option value="" selected={@form["vault_id"] in [nil, ""]}>
                    &#8212; none &#8212;
                  </option>
                  <option
                    :for={v <- @options.vaults}
                    value={v.id}
                    selected={@form["vault_id"] == v.id}
                  >
                    {v.name}
                  </option>
                </select>
                <p class="text-xs text-[var(--color-text-muted)]">
                  Layered on top of the environment's secrets. Vault values win on key collision.
                </p>
              </div>

              <div class="flex justify-end gap-2 pt-1">
                <button
                  type="button"
                  phx-click="close_picker"
                  class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  phx-disable-with="Adding…"
                  class="rounded-md px-3 py-1.5 text-sm font-medium bg-[var(--color-brand)] text-white hover:bg-[var(--color-brand-hover)]"
                >
                  Add to team
                </button>
              </div>
            </form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ── schedules panel ─────────────────────────────────────────────────────────

  attr :teammate, :map, required: true
  attr :schedules, :list, required: true
  attr :form, :any, required: true
  attr :editing, :any, default: nil
  attr :subscription_active, :boolean, default: true

  defp schedules_panel(assigns) do
    ~H"""
    <div id="team-schedules" class="relative z-50">
      <div
        class="fixed inset-0 bg-black/50 backdrop-blur-sm"
        phx-click="close_schedules"
        aria-hidden="true"
      />
      <div
        class="fixed inset-0 overflow-y-auto flex items-start sm:items-center justify-center p-4"
        role="dialog"
        aria-modal="true"
        aria-labelledby="team-schedules-title"
        phx-window-keydown="close_schedules"
        phx-key="escape"
      >
        <div class="relative w-full max-w-2xl rounded-xl shadow-xl bg-[var(--color-bg-1)] border border-[var(--color-border)]">
          <div class="flex items-center justify-between px-6 py-4 border-b border-[var(--color-border)]">
            <h2 id="team-schedules-title" class="text-base font-semibold">
              Schedules · {@teammate.name}
            </h2>
            <button
              type="button"
              phx-click="close_schedules"
              aria-label="Close"
              class="rounded p-1 text-[var(--color-text-secondary)] hover:bg-[var(--color-bg-2)]"
            >
              &times;
            </button>
          </div>

          <div class="px-6 py-4 text-sm space-y-5 max-h-[80vh] overflow-y-auto">
            <p class="text-[var(--color-text-secondary)]">
              A schedule sends {@teammate.name} a prompt on a cron. By default it goes into
              this conversation, like a message from you; a schedule set to run on a
              <span class="font-medium">one-off computer</span>
              opens a fresh conversation for each run instead — same agent, environment and vault —
              and leaves this thread alone. Times are UTC.
            </p>

            <div :if={@schedules == []} class="text-[var(--color-text-muted)] italic">
              No schedules yet.
            </div>

            <ul :if={@schedules != []} class="divide-y divide-[var(--color-border)]" role="list">
              <li
                :for={s <- @schedules}
                id={"schedule-#{s.id}"}
                class={["py-3 flex items-start justify-between gap-3", !s.enabled && "opacity-60"]}
              >
                <div class="min-w-0 space-y-0.5">
                  <div class="flex items-center gap-2 min-w-0">
                    <span class="font-medium truncate">{s.name || s.cron}</span>
                    <span class="shrink-0 rounded px-1.5 py-0.5 text-[10px] uppercase tracking-wide bg-[var(--color-bg-2)] text-[var(--color-text-secondary)]">
                      {if s.one_off, do: "one-off computer", else: "in thread"}
                    </span>
                    <span
                      :if={!s.enabled}
                      class="shrink-0 rounded px-1.5 py-0.5 text-[10px] uppercase tracking-wide bg-amber-100 text-amber-800"
                    >
                      paused
                    </span>
                  </div>
                  <div class="text-xs text-[var(--color-text-secondary)] font-mono">{s.cron}</div>
                  <div class="text-xs text-[var(--color-text-muted)] truncate" title={s.prompt}>
                    {s.prompt}
                  </div>
                  <div class="text-xs text-[var(--color-text-muted)]">
                    <span :if={s.enabled && s.next_run_at}>
                      next {format_run_time(s.next_run_at)}
                    </span>
                    <span :if={s.last_run_at}>
                      &middot; last {format_run_time(s.last_run_at)}
                      <.link
                        :if={s.last_conversation_id && is_nil(s.last_error)}
                        navigate={~p"/conversations/#{s.last_conversation_id}"}
                        class="underline"
                      >
                        view
                      </.link>
                      <span :if={s.last_error} class="text-rose-600">— {s.last_error}</span>
                    </span>
                  </div>
                </div>
                <div class="flex items-center gap-1.5 shrink-0 text-xs">
                  <button
                    :if={@subscription_active}
                    type="button"
                    phx-click="run_schedule"
                    phx-value-id={s.id}
                    phx-disable-with="…"
                    class="rounded-md border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-bg-2)]"
                    title="Run this prompt now"
                  >
                    Run now
                  </button>
                  <button
                    type="button"
                    phx-click="toggle_schedule"
                    phx-value-id={s.id}
                    class="rounded-md border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-bg-2)]"
                  >
                    {if s.enabled, do: "Pause", else: "Resume"}
                  </button>
                  <button
                    type="button"
                    phx-click="edit_schedule"
                    phx-value-id={s.id}
                    class="rounded-md border border-[var(--color-border)] px-2 py-1 hover:bg-[var(--color-bg-2)]"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    phx-click="delete_schedule"
                    phx-value-id={s.id}
                    data-confirm="Delete this schedule?"
                    class="rounded-md border border-rose-200 text-rose-700 px-2 py-1 hover:bg-rose-50"
                  >
                    Delete
                  </button>
                </div>
              </li>
            </ul>

            <.form
              :if={@form}
              for={@form}
              id="schedule-form"
              phx-change="validate_schedule"
              phx-submit="save_schedule"
              class="rounded-lg border border-[var(--color-border)] p-4 space-y-3 bg-[var(--color-bg-0)]"
            >
              <div class="font-medium">
                {if @editing, do: "Edit schedule", else: "New schedule"}
              </div>

              <div class="grid sm:grid-cols-2 gap-3">
                <label class="block">
                  <span class="text-xs text-[var(--color-text-secondary)]">Name (optional)</span>
                  <input
                    type="text"
                    name={@form[:name].name}
                    value={@form[:name].value}
                    placeholder="Morning standup"
                    class="mt-1 w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-1)] px-3 py-1.5 text-sm"
                  />
                  <.schedule_errors field={@form[:name]} />
                </label>
                <label class="block">
                  <span class="text-xs text-[var(--color-text-secondary)]">
                    Cron (UTC) — <span class="font-mono">min hour day month weekday</span>
                  </span>
                  <input
                    type="text"
                    name={@form[:cron].name}
                    value={@form[:cron].value}
                    list="cron-presets"
                    placeholder="0 9 * * 1-5"
                    required
                    class="mt-1 w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-1)] px-3 py-1.5 text-sm font-mono"
                  />
                  <datalist id="cron-presets">
                    <option value="0 * * * *">every hour</option>
                    <option value="0 9 * * *">daily at 09:00 UTC</option>
                    <option value="0 9 * * 1-5">weekdays at 09:00 UTC</option>
                    <option value="0 9 * * 1">Mondays at 09:00 UTC</option>
                    <option value="0 0 1 * *">first of the month</option>
                  </datalist>
                  <.schedule_errors field={@form[:cron]} />
                </label>
              </div>

              <label class="block">
                <span class="text-xs text-[var(--color-text-secondary)]">Prompt</span>
                <textarea
                  name={@form[:prompt].name}
                  rows="3"
                  required
                  placeholder={"What should #{@teammate.name} do each time?"}
                  class="mt-1 w-full rounded-md border border-[var(--color-border)] bg-[var(--color-bg-1)] px-3 py-1.5 text-sm"
                >{@form[:prompt].value}</textarea>
                <.schedule_errors field={@form[:prompt]} />
              </label>

              <label class="flex items-start gap-2">
                <input type="hidden" name={@form[:one_off].name} value="false" />
                <input
                  type="checkbox"
                  name={@form[:one_off].name}
                  value="true"
                  checked={truthy?(@form[:one_off].value)}
                  class="mt-0.5 rounded border-[var(--color-border)]"
                />
                <span>
                  <span class="font-medium">Run in a one-off computer</span>
                  <span class="block text-xs text-[var(--color-text-secondary)]">
                    Each run opens a fresh conversation on a new computer with the same agent,
                    environment and vault, instead of messaging {@teammate.name} here.
                  </span>
                </span>
              </label>

              <label :if={@editing} class="flex items-center gap-2">
                <input type="hidden" name={@form[:enabled].name} value="false" />
                <input
                  type="checkbox"
                  name={@form[:enabled].name}
                  value="true"
                  checked={truthy?(@form[:enabled].value)}
                  class="rounded border-[var(--color-border)]"
                />
                <span>Enabled</span>
              </label>

              <div class="flex items-center gap-2 pt-1">
                <button
                  type="submit"
                  phx-disable-with="Saving…"
                  class="rounded-md px-3 py-1.5 text-sm font-medium bg-[var(--color-brand)] text-white hover:bg-[var(--color-brand-hover)]"
                >
                  {if @editing, do: "Save changes", else: "Add schedule"}
                </button>
                <button
                  :if={@editing}
                  type="button"
                  phx-click="cancel_edit_schedule"
                  class="rounded-md border border-[var(--color-border)] px-3 py-1.5 text-sm hover:bg-[var(--color-bg-2)]"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :field, Phoenix.HTML.FormField, required: true

  defp schedule_errors(assigns) do
    errors =
      if Phoenix.Component.used_input?(assigns.field),
        do: Enum.map(assigns.field.errors, &format_error/1),
        else: []

    assigns = assign(assigns, :errors, errors)

    ~H"""
    <p :for={msg <- @errors} class="mt-1 text-xs text-rose-600">{msg}</p>
    """
  end

  # Changeset errors carry `%{count}`-style placeholders; fill them in.
  defp format_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end

  defp truthy?(true), do: true
  defp truthy?("true"), do: true
  defp truthy?(_), do: false

  defp format_run_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%b %-d %H:%M UTC")
  defp format_run_time(_), do: ""
end
