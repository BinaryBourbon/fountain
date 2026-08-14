defmodule FountainWeb.ConversationsLive.LegacyBlocks do
  @moduledoc """
  Translate stored legacy-dialect stdout lines into the block maps the
  conversation view renders.

  This is the twin of `Fountain.Runtimes.ACP.Blocks`, for the `stdout` stream:
  the four hand-written parsers that used to be 24 `event_blocks/2` clauses
  inside the LiveView render path (#642). Getting them out of `show.ex` was
  ADR 0014's original complaint — a vendor's point release becoming our
  rendering bug, in the render path, with no tests of their own.

  ## What is live and what is frozen

  - **gemini** is the only dialect still *produced*: its ACP conversion is
    held back by an upstream defect (#659), so gemini turns keep writing
    stream-json to the `stdout` stream and this parser keeps earning its
    place.
  - **claude, codex, opencode** are **frozen**: their runtimes speak only ACP
    now, so their parsers exist solely to render `stdout` rows recorded
    before the conversion. Frozen means exactly that — the input set is
    historical and can no longer change, so these clauses must never be
    extended. When pre-ACP history ages out of retention, they are deleted.

  **A dialect parser must never be written again.** A fifth runtime that does
  not speak ACP gets an adapter at the sandbox boundary, not a fifth set of
  clauses here (and never one in `cli/` — ADR 0015).

  Unrecognised lines render as `:raw` blocks rather than disappearing:
  something will always write a non-protocol line to stdout, and visible
  noise beats silent loss.
  """

  @doc """
  Translate one stored stdout line into blocks for `runtime`'s dialect.

  Returns `[%{kind: :raw, ...}]` for anything the dialect does not claim.
  """
  @spec from_line(String.t(), String.t() | nil) :: [map()]
  def from_line(line, runtime) do
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

  # ── claude (stream-json) — FROZEN: renders pre-ACP history only ────────────
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

  # ── codex (`codex exec --json`) — FROZEN: renders pre-ACP history only ─────
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

  # ── gemini (`gemini --output-format stream-json`) — LIVE (#659) ────────────
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

  # ── opencode (`opencode run --format json`) — FROZEN: pre-ACP history ──────
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

  # Unknown dialect or unclaimed event — caller falls back to a :raw block.
  defp event_blocks(_runtime, _decoded), do: nil

  # ── helpers ────────────────────────────────────────────────────────────────

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

  defp format_duration_ms(ms) when is_integer(ms) and ms < 1_000, do: "#{ms}ms"
  defp format_duration_ms(ms) when is_integer(ms), do: "#{Float.round(ms / 1000, 1)}s"
  defp format_duration_ms(_), do: ""

  defp format_status(nil), do: nil
  defp format_status(s), do: to_string(s)
end
