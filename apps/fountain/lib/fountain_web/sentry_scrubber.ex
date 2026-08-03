defmodule FountainWeb.SentryScrubber do
  @moduledoc """
  Body scrubber for `Sentry.PlugContext` (#402).

  Sentry's default scrubber is a denylist of three exact parameter names
  (`password`, `passwd`, `secret`), so the secret-write endpoints
  (`%{"key" => ..., "value" => <plaintext>}`) and the manifest apply's
  `spec.secrets` map sailed through it verbatim — any exception mid-request
  shipped tenant plaintext to Sentry.

  This app holds tenant secrets by definition, so the policy is an
  allowlist of *shape*, not a longer denylist the next endpoint outruns:
  every string value is replaced with a length tag, keeping only the
  structure (keys, nesting, sizes) that debugging actually uses.
  """

  @doc """
  Returns `conn.params` with every string value replaced by `"[string:N]"`.

  Numbers, booleans and nil pass through — they carry no secret material
  and are the values most often load-bearing in an error report. Anything
  else (uploads, structs) is flattened to a tag.
  """
  def scrub_body(%Plug.Conn{params: %Plug.Conn.Unfetched{}}), do: %{}
  def scrub_body(%Plug.Conn{params: params}), do: summarize(params)

  defp summarize(%Plug.Upload{filename: name}), do: "[upload:#{name}]"
  defp summarize(%_{} = _struct), do: "[struct]"
  defp summarize(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, summarize(v)} end)
  defp summarize(list) when is_list(list), do: Enum.map(list, &summarize/1)
  defp summarize(value) when is_binary(value), do: "[string:#{byte_size(value)}]"

  defp summarize(value) when is_number(value) or is_boolean(value) or is_nil(value),
    do: value

  defp summarize(_other), do: "[redacted]"
end
