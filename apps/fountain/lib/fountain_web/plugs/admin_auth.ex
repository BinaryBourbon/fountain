defmodule FountainWeb.Plugs.AdminAuth do
  @moduledoc """
  Single-tenant bearer auth: `Authorization: Bearer <ADMIN_TOKEN>`.
  Compares constant-time against the configured token.
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    expected = Application.fetch_env!(:fountain, :admin_token)

    with ["Bearer " <> presented] <- get_req_header(conn, "authorization"),
         true <- Plug.Crypto.secure_compare(presented, expected) do
      conn
    else
      _ ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, ~s({"error":"unauthorized"}))
        |> halt()
    end
  end
end
