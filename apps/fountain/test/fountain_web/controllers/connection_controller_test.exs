defmodule FountainWeb.ConnectionControllerTest do
  # Flips the broker ratchet (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.Google

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")
    enable_broker_for([user.id])

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  test "an account the broker is not on for gets 404 on every route", %{conn: conn} do
    Application.put_env(:fountain, :broker_tenants, [])

    assert %{"error" => "connections_not_enabled"} =
             conn |> get("/api/connections") |> json_response(404)

    assert %{"error" => "connections_not_enabled"} =
             conn |> get("/api/connections/providers") |> json_response(404)
  end

  test "lists, shows and deletes the caller's connections without a token", %{conn: conn, user: user} do
    c = insert_connection(user, account_email: "me@example.com", access_token: "never-shown-at")
    other = insert_verified_user()
    enable_broker_for([user.id, other.id])
    insert_connection(other, account_email: "them@example.com")

    body = conn |> get("/api/connections") |> json_response(200)
    assert [%{"id" => id, "account_email" => "me@example.com", "status" => "active", "env_key" => "GOOGLE_ACCESS_TOKEN"}] = body["data"]
    assert id == c.id
    refute inspect(body) =~ "never-shown-at"

    assert %{"id" => ^id, "provider" => "google"} = conn |> get("/api/connections/#{id}") |> json_response(200)

    Req.Test.stub(Google, fn req -> Req.Test.json(req, %{}) end)
    assert conn |> delete("/api/connections/#{id}") |> response(204)
    assert Connections.list_connections(user.id) == []
    assert conn |> get("/api/connections/#{id}") |> json_response(404)
  end

  test "providers names Google, its scopes and where to start", %{conn: conn} do
    assert %{"data" => [google]} = conn |> get("/api/connections/providers") |> json_response(200)
    assert google["provider"] == "google"
    assert google["configured"] == true
    assert google["env_key"] == "GOOGLE_ACCESS_TOKEN"
    assert google["connect_url"] =~ "/connections/google/start"
    assert "https://www.googleapis.com/auth/gmail.modify" in google["scopes"]
  end

  test "a sprite-scoped key cannot see connections", %{user: user} do
    {_k, sprite_key} = insert_sprite_api_key(user)

    build_conn()
    |> put_req_header("authorization", "Bearer #{sprite_key}")
    |> put_req_header("accept", "application/json")
    |> get("/api/connections")
    |> json_response(403)
  end
end
