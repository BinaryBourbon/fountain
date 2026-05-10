defmodule FountainWeb.Plugs.TenantAPIAuth do
  @moduledoc """
  API pipeline auth: extracts `Authorization: Bearer <key>`, SHA-256 hashes it,
  looks up the active API key, loads the owning user, and sets
  `conn.assigns.current_user`.

  Updates `last_used_at` asynchronously via `Task.async` so it never blocks
  the request.

  Returns 401 JSON on failure.
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
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or missing API key"})
        |> halt()
    end
  end
end
