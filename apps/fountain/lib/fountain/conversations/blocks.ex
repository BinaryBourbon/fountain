defmodule Fountain.Conversations.Blocks do
  @moduledoc """
  A log event's `data`, as the structured blocks a client renders — the one
  seam between what the runtime wrote and what a transcript shows.

  Keyed on the event's *stream*, not the conversation's runtime: the `acp`
  stream is parsed by `Managoat.ACP.Blocks`, the legacy `stdout`
  dialects by `Fountain.Runtimes.LegacyBlocks` for the runtime that wrote
  them. The per-agent ACP flag can flip between turns, and the turns before
  it flipped must keep rendering through the parser that produced them
  (0014, #642).

  This used to live in the web UI's transcript component. It moved here so the
  API can serve blocks too (`?blocks=true` on `/events` and the streams) and a
  client on another origin never re-parses a vendor dialect — ADR 0014's
  principle applied to the wire, not just to a render path. Since #867 that is
  the only path: the transcript itself is a client.

  ## Block shapes

  Maps with a `:kind` atom; the rest is per kind. `to_json/1` is the wire
  form: `kind` as a string, `error?` as `error`, nothing else renamed.

  | kind | fields |
  |---|---|
  | `:text`, `:thinking` | `body` |
  | `:tool_use` | `id`, `name`, `summary`, `body` (the input) |
  | `:tool_result` | `tool_id`, `body`, `error?` |
  | `:init` | `summary`, `body` |
  | `:result` | `body`, `raw` |
  | `:error` | `body` |
  | `:raw` | `body`, `summary` |
  | `:permission_request` | `request_id`, `name`, `summary`, `options` |

  A `tool_result` is paired to its `tool_use` on `tool_id`; that is the
  client's pass (`pair_tool_results` in the LiveView, the same in the SPA),
  because the two arrive as separate events.
  """

  alias Fountain.Runtimes.LegacyBlocks

  @kinds ~w(text thinking tool_use tool_result init result error raw permission_request)

  @doc "Every `kind` a block can have — the wire enum."
  def kinds, do: @kinds

  @doc "The blocks one log event's data holds, for `runtime`'s dialect when it is a legacy stdout row."
  @spec for_event(map(), String.t() | nil) :: [map()]
  def for_event(%{stream: "acp", data: data}, _runtime) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&Managoat.ACP.Blocks.from_line/1)
  end

  def for_event(%{data: data}, runtime) when is_binary(data) do
    data
    |> String.split("\n", trim: true)
    |> Enum.flat_map(&LegacyBlocks.from_line(&1, runtime))
  end

  def for_event(_, _), do: []

  @doc """
  The assistant's text across `events` — every `:text` block of each output
  event, joined, trimmed — for `runtime`'s dialect on legacy rows. What a
  chat bubble shows for a turn's reply, what the roster previews, and what
  `Fountain.Search` indexes (`turns.reply_text`). `""` when there is none.
  """
  @spec assistant_text([map()], String.t() | nil) :: String.t()
  def assistant_text(events, runtime) do
    events
    |> Enum.filter(
      &(&1.kind == "output" and &1.stream in ["stdout", "acp"] and is_binary(&1.data))
    )
    |> Enum.flat_map(&for_event(&1, runtime))
    |> Enum.flat_map(fn
      %{kind: :text, body: t} when is_binary(t) -> [t]
      _ -> []
    end)
    |> Enum.join("")
    |> String.trim()
  end

  @doc "The wire form of a block: string `kind`, `error` for `error?`, everything else as is."
  @spec to_json(map()) :: map()
  def to_json(%{kind: kind} = block) do
    block
    |> Map.new(fn
      {:kind, k} -> {"kind", Atom.to_string(k)}
      {:error?, v} -> {"error", v}
      {k, v} -> {Atom.to_string(k), v}
    end)
    |> Map.put("kind", Atom.to_string(kind))
  end
end
