defmodule FountainWeb.Plugs.TenantAPIAuth do
  @moduledoc """
  API pipeline auth: extracts `Authorization: Bearer <key>`, SHA-256 hashes it,
  looks up the API key, loads the owning user, and sets
  `conn.assigns.current_user`.

  Updates `last_used_at` asynchronously via `Task.async` so it never blocks
  the request.

  Returns 401 JSON on failure. The response body includes a machine-readable
  `reason` so clients (especially in-sprite agents holding a rotated
  `$FOUNTAIN_TOKEN`) can tell a revoked key apart from one that never existed:

      {"error": "API key has been revoked", "reason": "api_key_revoked"}
      {"error": "Invalid or missing API key", "reason": "api_key_invalid"}
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    with [auth_header] <- get_req_header(conn, "authorization"),
         "Bearer " <> raw_key <- auth_header,
         {:ok, user} <- Accounts.get_user_by_api_key(raw_key) do
      Task.async(fn -> Accounts.touch_api_key(raw_key) end)
      assign(conn, :current_user, user)
    else
      {:error, :revoked} ->
        unauthorized(conn, "API key has been revoked", "api_key_revoked")

      _ ->
        unauthorized(conn, "Invalid or missing API key", "api_key_invalid")
    end
  end

  defp unauthorized(conn, message, reason) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: message, reason: reason})
    |> halt()
  end
end
