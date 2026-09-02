defmodule Managoat.ACP.Usage do
  @moduledoc """
  The end-of-turn token figure, normalised from a `session/prompt` response
  (#827).

  Two places a runtime puts it, tried in order:

    * `usage` — the (unstable, as of protocol v1) `Usage` object:
      `inputTokens`, `outputTokens`, `cachedReadTokens`, `cachedWriteTokens`,
      `totalTokens`, `thoughtTokens`. claude-agent-acp ≥ 0.6x fills it with
      the turn's accumulated API usage (reset when the turn starts) and
      codex-acp with the thread's last token count;
    * `_meta.inputTokens` / `_meta.outputTokens` — where an adapter put it
      before the field had a name.

  The result is one flat, string-keyed map (so it can go straight into a
  JSON column): `%{"input" => n, "output" => n}` plus `"cache_read"` /
  `"cache_write"` when reported. `nil` when the response carries neither — a turn without a
  usage, not a zero one.

  Deliberately *not* derived from the `usage_update` notifications that
  stream during a turn: those are context-window occupancy (`used` / `size`)
  and a cumulative session `cost`, and what they mean per update differs by
  runtime. The one figure recorded per turn is the one the runtime reports
  when the turn ends.
  """

  @type t :: %{required(String.t()) => non_neg_integer()}

  @doc "The turn's usage from a `session/prompt` result, or nil."
  @spec from_prompt_result(map() | nil) :: t() | nil
  def from_prompt_result(%{"usage" => %{} = usage}), do: normalize(usage)
  def from_prompt_result(%{"_meta" => %{} = meta}), do: normalize(meta)
  def from_prompt_result(_), do: nil

  defp normalize(source) do
    input = count(source["inputTokens"])
    output = count(source["outputTokens"])

    if is_nil(input) and is_nil(output) do
      nil
    else
      %{"input" => input || 0, "output" => output || 0}
      |> put_present("cache_read", count(source["cachedReadTokens"]))
      |> put_present("cache_write", count(source["cachedWriteTokens"]))
    end
  end

  # An adapter that reports a float or a numeric string still counts;
  # anything else (a negative, a bool, an object) is "not reported".
  defp count(n) when is_integer(n) and n >= 0, do: n
  defp count(n) when is_float(n) and n >= 0, do: trunc(n)

  defp count(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp count(_), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
