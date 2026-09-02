defmodule Managoat.Sandbox.Sprites.Errors do
  @moduledoc """
  Normalizes `sprites-ex` error shapes into the `Managoat.Sandbox` taxonomy.

  The SDK surfaces HTTP failures as `{:api_error, status, body}` (plus
  `{:not_found, body}` from the get endpoint) and transport failures as
  whatever `Req` produced. Nothing outside the Sprites adapter should ever
  see those shapes — `Managoat.Sandbox.Retry.transient?/1` and the not-found
  handling in the wake path classify on the normalized terms only.
  """

  alias Managoat.Sandbox

  @doc "Map a raw sprites-ex error reason onto `t:Managoat.Sandbox.error/0`."
  @spec normalize(term()) :: Sandbox.error()
  def normalize({:not_found, _body}), do: :not_found
  def normalize({:api_error, 404, _body}), do: :not_found

  def normalize({:api_error, status, body}) when status in [401, 403],
    do: {:denied, {:http, status, body}}

  def normalize({:api_error, 429, body}), do: {:rate_limited, retry_after(body)}

  def normalize({:api_error, status, body}) when status >= 500,
    do: {:unavailable, {:http, status, body}}

  def normalize({:api_error, status, body}), do: {:invalid, {:http, status, body}}

  def normalize(:timeout), do: {:unavailable, :timeout}
  def normalize(%Req.TransportError{} = e), do: {:unavailable, e}
  def normalize(%Mint.TransportError{} = e), do: {:unavailable, e}

  def normalize(reason), do: {:provider, :sprites, reason}

  # Sprites rate-limit bodies carry `retry_after_seconds` (see the contract
  # doc, "Errors"); anything else degrades to a bare rate-limited.
  defp retry_after(%{"retry_after_seconds" => seconds}) when is_integer(seconds) and seconds >= 0,
    do: seconds

  defp retry_after(_body), do: nil
end
