defmodule Fountain.Sandbox.Daytona.Errors do
  @moduledoc """
  Normalizes Daytona error shapes into the `Fountain.Sandbox` taxonomy —
  the same mapping discipline as the other adapters, tagged `:daytona`.
  """

  alias Fountain.Sandbox

  @spec normalize(term()) :: Sandbox.error()
  def normalize(:not_found), do: :not_found
  def normalize(:truncated), do: :truncated
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

  def normalize(reason), do: {:provider, :daytona, reason}

  defp retry_after(%{"retryAfter" => s}) when is_integer(s) and s >= 0, do: s
  defp retry_after(_body), do: nil
end
