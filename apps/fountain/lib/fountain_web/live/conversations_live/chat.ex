defmodule FountainWeb.ConversationsLive.Chat do
  @moduledoc """
  The chat rendering of a conversation — one bubble per side per turn — shared
  by `ConversationsLive.Show` (its `chat` view mode) and `TeamLive` (the
  iMessage-style team page), so the two never drift on how a turn reads.

  Also home to `blocks_for/2`, the one seam that turns a log event's `data`
  into structured blocks: keyed on the event's *stream*, not the
  conversation's runtime, because the per-agent ACP flag can flip between
  turns and the turns before it flipped must keep rendering through the
  parser that produced them (0014, #642).
  """
  use Phoenix.Component

  attr :turns, :map, required: true
  attr :events, :list, required: true
  attr :conv, :map, required: true

  def chat_view(assigns) do
    by_turn = Enum.group_by(assigns.events, & &1.turn_id)

    turns =
      assigns.turns
      |> Map.values()
      |> Enum.sort_by(& &1.turn_number)

    assigns = assign(assigns, ordered_turns: turns, events_by_turn: by_turn)

    ~H"""
    <div class="space-y-6">
      <%= for turn <- @ordered_turns do %>
        <.chat_turn turn={turn} events={Map.get(@events_by_turn, turn.id, [])} conv={@conv} />
      <% end %>
    </div>
    """
  end

  attr :turn, :map, required: true
  attr :events, :list, required: true
  attr :conv, :map, required: true

  def chat_turn(assigns) do
    reply = chat_assistant_reply(assigns.events, assigns.conv.runtime)
    agent_name = assigns.conv.agent && assigns.conv.agent.name
    runtime_label = assigns.conv.runtime
    image_count = Map.get(assigns.turn, :image_count, 0)

    avatar_url =
      case assigns.conv.agent do
        %{id: id, avatar_media_type: mt} when is_binary(mt) -> "/agents/#{id}/avatar"
        _ -> nil
      end

    assigns =
      assign(assigns,
        reply: reply,
        agent_name: agent_name || runtime_label,
        agent_glyph: agent_glyph(runtime_label),
        avatar_url: avatar_url,
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
              <img
                src={"/conversations/#{@conv.id}/turns/#{@turn.id}/images/#{pos}"}
                class="max-w-[300px] max-h-[200px] object-contain rounded border border-blue-400/30"
              />
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
        avatar_url={@avatar_url}
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
        avatar_url={@avatar_url}
        glyph_class="bg-zinc-200 text-zinc-700"
        timestamp={nil}
        muted
      >
        <div class="flex items-center gap-1.5">
          <span class="size-1.5 rounded-full bg-zinc-400 animate-pulse" />
          <span class="size-1.5 rounded-full bg-zinc-400 animate-pulse [animation-delay:200ms]" />
          <span class="size-1.5 rounded-full bg-zinc-400 animate-pulse [animation-delay:400ms]" />
        </div>
      </.chat_message>

      <.chat_message
        :if={@reply == "" and @turn.status not in ["running", "completed"]}
        role={:assistant}
        name={@agent_name}
        avatar={@agent_glyph}
        avatar_url={@avatar_url}
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
  attr :avatar_url, :string, default: nil
  attr :glyph_class, :string, required: true
  attr :timestamp, :any, default: nil
  attr :muted, :boolean, default: false
  slot :inner_block, required: true

  def chat_message(assigns) do
    ~H"""
    <div class={[
      "flex gap-3 items-start",
      @role == :user && "flex-row-reverse"
    ]}>
      <div class={[
        "shrink-0 size-8 rounded-full flex items-center justify-center text-sm shadow-sm overflow-hidden",
        @glyph_class
      ]}>
        <img :if={@avatar_url} src={@avatar_url} class="w-full h-full object-cover" />
        <span :if={is_nil(@avatar_url)}>{@avatar}</span>
      </div>
      <div class={[
        "max-w-[78%] flex flex-col gap-1",
        @role == :user && "items-end"
      ]}>
        <div class="flex items-baseline gap-2 px-1">
          <span class="text-xs font-medium text-zinc-700">{@name}</span>
          <span :if={@timestamp} class="text-[10px] text-zinc-400 font-mono">
            {format_chat_time(@timestamp)}
          </span>
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

  # Agent output is untrusted by construction (sandboxed code, prompt
  # injection) — FountainWeb.Markdown strips javascript:-style URL schemes
  # and neutralizes the raw HTML a plain markdown render lets through (#323).
  defp render_markdown(text), do: FountainWeb.Markdown.to_html(text)

  defp format_chat_time(nil), do: ""

  defp format_chat_time(%DateTime{} = dt) do
    dt
    |> DateTime.shift_zone!("Etc/UTC")
    |> Calendar.strftime("%H:%M")
  end

  defp format_chat_time(_), do: ""

  def agent_glyph("claude"), do: "✦"
  def agent_glyph("codex"), do: "◇"
  def agent_glyph("gemini"), do: "◈"
  def agent_glyph("opencode"), do: "◉"
  def agent_glyph(_), do: "🤖"

  # Walk this turn's events and pull out every `:text` block from each
  # runtime's stream-json. Joined so multi-message turns (claude can
  # emit several assistant messages, gemini streams deltas) read as
  # one contiguous reply.
  def chat_assistant_reply(events, runtime) do
    events
    |> Enum.filter(
      &(&1.kind == "output" and &1.stream in ["stdout", "acp"] and is_binary(&1.data))
    )
    |> Enum.flat_map(&blocks_for(&1, runtime))
    |> Enum.flat_map(fn
      %{kind: :text, body: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  # ── event → blocks ──────────────────────────────────────────────

  # Splits an event's `data` (which may be a stream-json chunk with N
  # lines) into a flat list of structured blocks. Each block is a map
  # with at least `:kind`, plus kind-specific fields.
  # ACP rows carry a specified protocol rather than a vendor's dialect, so the
  # translation lives on the server in `Fountain.Runtimes.ACP.Blocks` — with its
  # own tests, and outside the render path where a point release becomes a
  # rendering bug. That relocation is the point of 0014; this clause is the
  # seam, and it is deliberately the only ACP knowledge in this module.
  #
  # Keyed on the event's stream, not the conversation's runtime: the per-agent
  # flag can flip between turns, and the turns before it flipped must keep
  # rendering through the parser that produced them.
  def blocks_for(%{stream: "acp", data: data}, _runtime) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&Fountain.Runtimes.ACP.Blocks.from_line/1)
  end

  # Legacy stdout rows: gemini's live dialect (#659) and pre-ACP history for
  # the converted runtimes. The parsers live in `LegacyBlocks`, out of the
  # render path, with their own tests — this clause is the whole seam (#642).
  def blocks_for(%{data: data}, runtime) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&FountainWeb.ConversationsLive.LegacyBlocks.from_line(&1, runtime))
  end

  def blocks_for(_, _), do: []
end
