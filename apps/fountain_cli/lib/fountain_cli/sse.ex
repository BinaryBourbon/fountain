defmodule FountainCli.Sse do
  @moduledoc "Tiny SSE event-stream parser."

  @doc """
  Feed bytes; returns `{events, leftover}`. Each event is a map with
  optional `:id`, `:event`, and `:data` (decoded JSON if it parses, raw
  string otherwise).
  """
  def feed(buffer) do
    parts = String.split(buffer, "\n\n")
    {complete, [tail]} = Enum.split(parts, -1)
    events = Enum.map(complete, &parse/1) |> Enum.reject(&is_nil/1)
    {events, tail}
  end

  defp parse(""), do: nil
  # heartbeat / comment
  defp parse(":" <> _), do: nil

  defp parse(block) do
    block
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{}, fn line, acc ->
      case String.split(line, ": ", parts: 2) do
        ["id", v] -> Map.put(acc, :id, parse_int(v))
        ["event", v] -> Map.put(acc, :event, v)
        ["data", v] -> Map.update(acc, :data, decode(v), &(&1 <> "\n" <> decode_passthrough(v)))
        _ -> acc
      end
    end)
    |> case do
      m when map_size(m) == 0 -> nil
      m -> m
    end
  end

  defp parse_int(s) do
    case Integer.parse(s) do
      {n, _} -> n
      _ -> 0
    end
  end

  defp decode(v) do
    case Jason.decode(v) do
      {:ok, m} -> m
      _ -> v
    end
  end

  defp decode_passthrough(v), do: v
end
