defmodule Fountain.Runtimes.Claude.StreamTracer do
  @moduledoc """
  Bridges Claude's `--output-format stream-json` stdout into the active OTel
  turn span.

  Claude emits one newline-delimited JSON object per event. This module buffers
  incomplete lines across chunk boundaries, then for each complete line:

  - **`system` / `init`**: adds a span event with model + tool count; sets
    `fountain.claude_model` on the turn span.
  - **`assistant`** with `tool_use` content: opens a child `fountain.tool_use`
    span, keyed by `tool_use_id`.
  - **`assistant`** with `text` / `thinking` content: adds a span event
    recording the byte length (content itself is not stored in traces).
  - **`tool_result`**: closes the matching `fountain.tool_use` child span;
    marks it as an error if `is_error: true`.
  - **`result`**: sets duration, cost, and token-usage attributes on the turn
    span; adds a `claude.result` span event.

  Non-JSON lines (e.g. debug output written to stdout) are silently skipped.

  ## Usage

      tracer = StreamTracer.new(turn_span_ctx)
      tracer = StreamTracer.handle_chunk(tracer, chunk)
      StreamTracer.finalize(tracer)   # call on turn end / interrupt

  All functions are no-ops when passed `nil`, so the caller can keep a `nil`
  tracer for non-Claude runtimes without branching.
  """

  require OpenTelemetry.Tracer, as: Tracer

  @type t :: %{
          line_buffer: binary(),
          turn_span_ctx: term(),
          open_tool_spans: %{binary() => term()}
        }

  @doc "Create a new stream tracer attached to `turn_span_ctx`."
  @spec new(term()) :: t()
  def new(turn_span_ctx) do
    %{
      line_buffer: "",
      turn_span_ctx: turn_span_ctx,
      open_tool_spans: %{}
    }
  end

  @doc """
  Feed a raw stdout chunk into the tracer. Returns updated tracer state.
  Pass `nil` to no-op (useful for non-Claude runtimes).
  """
  @spec handle_chunk(t() | nil, binary()) :: t() | nil
  def handle_chunk(nil, _data), do: nil

  def handle_chunk(%{line_buffer: buf} = tracer, data) when is_binary(data) do
    full = buf <> data
    {complete_lines, remaining} = split_lines(full)
    Enum.reduce(complete_lines, %{tracer | line_buffer: remaining}, &handle_line(&2, &1))
  end

  @doc """
  Close any tool spans that are still open (runtime exited mid-turn or was
  interrupted before emitting matching `tool_result` events).
  Pass `nil` to no-op.
  """
  @spec finalize(t() | nil) :: :ok
  def finalize(nil), do: :ok

  def finalize(%{open_tool_spans: spans, turn_span_ctx: turn_ctx}) when map_size(spans) == 0 do
    Tracer.set_current_span(turn_ctx)
    :ok
  end

  def finalize(%{open_tool_spans: spans, turn_span_ctx: turn_ctx}) do
    Tracer.set_current_span(turn_ctx)

    Enum.each(spans, fn {_id, span_ctx} ->
      Tracer.set_current_span(span_ctx)
      Tracer.set_attribute("fountain.tool_status", "abandoned")
      Tracer.set_status(OpenTelemetry.status(:error, "turn ended with open tool call"))
      Tracer.end_span(span_ctx)
    end)

    Tracer.set_current_span(turn_ctx)
    :ok
  end

  # ── private ───────────────────────────────────────────────────────────────

  # Split at newlines; last element is the (possibly empty) incomplete tail.
  defp split_lines(s) do
    parts = String.split(s, "\n")
    {complete, [tail]} = Enum.split(parts, -1)
    {complete, tail}
  end

  defp handle_line(tracer, ""), do: tracer

  defp handle_line(tracer, line) do
    case Jason.decode(line) do
      {:ok, event} -> process_event(tracer, event)
      # Non-JSON lines (e.g. debug/warning output) — silently ignore.
      {:error, _} -> tracer
    end
  end

  # ── event handlers ────────────────────────────────────────────────────────

  # System init: record model + tool count.
  defp process_event(tracer, %{"type" => "system", "subtype" => "init"} = event) do
    Tracer.set_current_span(tracer.turn_span_ctx)
    model = Map.get(event, "model", "")
    tools = length(Map.get(event, "tools", []))

    Tracer.set_attribute("fountain.claude_model", model)

    Tracer.add_event("claude.init", %{
      "model" => model,
      "tools_count" => tools
    })

    tracer
  end

  # Assistant message: process each content block.
  defp process_event(tracer, %{"type" => "assistant", "message" => message}) do
    Tracer.set_current_span(tracer.turn_span_ctx)
    content = Map.get(message, "content", [])
    Enum.reduce(content, tracer, &process_content_block(&2, &1))
  end

  # Tool result: close the matching child span.
  defp process_event(tracer, %{"type" => "tool_result", "tool_use_id" => tool_id} = event) do
    case Map.pop(tracer.open_tool_spans, tool_id) do
      {nil, _} ->
        tracer

      {span_ctx, remaining} ->
        Tracer.set_current_span(span_ctx)
        is_error = Map.get(event, "is_error", false)
        Tracer.set_attribute("fountain.tool_is_error", is_error)

        if is_error do
          Tracer.set_status(OpenTelemetry.status(:error, "tool returned error"))
        end

        Tracer.end_span(span_ctx)
        Tracer.set_current_span(tracer.turn_span_ctx)
        %{tracer | open_tool_spans: remaining}
    end
  end

  # Final result: set cost/duration/token attributes on the turn span.
  defp process_event(tracer, %{"type" => "result"} = event) do
    Tracer.set_current_span(tracer.turn_span_ctx)

    set_if_present(event, "duration_ms", "fountain.duration_ms")
    set_if_present(event, "duration_api_ms", "fountain.duration_api_ms")
    set_if_present(event, "num_turns", "fountain.num_turns")
    set_if_present(event, "total_cost_usd", "fountain.total_cost_usd")

    if usage = Map.get(event, "usage") do
      set_if_present(usage, "input_tokens", "fountain.input_tokens")
      set_if_present(usage, "output_tokens", "fountain.output_tokens")
      set_if_present(usage, "cache_read_input_tokens", "fountain.cache_read_tokens")
      set_if_present(usage, "cache_creation_input_tokens", "fountain.cache_write_tokens")
    end

    Tracer.add_event("claude.result", %{
      "subtype" => Map.get(event, "subtype", ""),
      "is_error" => Map.get(event, "is_error", false)
    })

    tracer
  end

  defp process_event(tracer, _event), do: tracer

  # ── content block handlers ────────────────────────────────────────────────

  # Tool use block: open a child span for the tool call.
  defp process_content_block(tracer, %{"type" => "tool_use", "id" => id, "name" => name}) do
    Tracer.set_current_span(tracer.turn_span_ctx)

    span_ctx =
      Tracer.start_span("fountain.tool_use", %{
        attributes: %{
          "fountain.tool_name" => name,
          "fountain.tool_id" => id
        }
      })

    %{tracer | open_tool_spans: Map.put(tracer.open_tool_spans, id, span_ctx)}
  end

  # Text output: add a span event with byte length (not the content itself).
  defp process_content_block(tracer, %{"type" => "text", "text" => text}) do
    Tracer.set_current_span(tracer.turn_span_ctx)
    Tracer.add_event("claude.text", %{"length" => byte_size(text)})
    tracer
  end

  # Extended thinking block.
  defp process_content_block(tracer, %{"type" => "thinking", "thinking" => thinking}) do
    Tracer.set_current_span(tracer.turn_span_ctx)
    Tracer.add_event("claude.thinking", %{"length" => byte_size(thinking)})
    tracer
  end

  defp process_content_block(tracer, _block), do: tracer

  # ── helpers ───────────────────────────────────────────────────────────────

  defp set_if_present(map, key, attr) do
    case Map.get(map, key) do
      nil -> :ok
      v -> Tracer.set_attribute(attr, v)
    end
  end
end
