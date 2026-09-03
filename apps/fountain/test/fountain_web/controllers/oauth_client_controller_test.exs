defmodule FountainWeb.OAuthClientControllerTest do
  @moduledoc "The OAuth clients an account registers for itself over /api (#1125)."
  use FountainWeb.ConnCase, async: true

  alias Fountain.OAuth

  setup %{conn: conn} do
    user = insert_verified_user()
    {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "t")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{raw}")
      |> put_req_header("accept", "application/json")

    {:ok, conn: conn, user: user}
  end

  describe "POST /api/oauth/clients" do
    test "registers a client and hands back the generated client_id", %{conn: conn} do
      body =
        conn
        |> post("/api/oauth/clients", %{
          "name" => "Notes",
          "redirect_uris" => ["https://abc123.sprites.app/callback"]
        })
        |> json_response(201)

      assert body["name"] == "Notes"
      assert String.starts_with?(body["client_id"], "app_")
      assert body["published"] == false
      assert body["origins"] == ["https://abc123.sprites.app"]
    end

    test "422s a redirect URI that cannot work", %{conn: conn} do
      body =
        conn
        |> post("/api/oauth/clients", %{"name" => "Notes", "redirect_uris" => []})
        |> json_response(422)

      assert body["errors"]["redirect_uris"] == ["add at least one redirect URI"]
    end

    test "the registration is enough for CORS from that origin", %{conn: conn} do
      conn
      |> post("/api/oauth/clients", %{
        "name" => "Notes",
        "redirect_uris" => ["https://abc123.sprites.app/callback"]
      })
      |> json_response(201)

      assert OAuth.registered_origin?("https://abc123.sprites.app")
    end
  end

  describe "GET /api/oauth/clients" do
    test "lists only the caller's", %{conn: conn, user: user} do
      mine = insert_oauth_client(user_id: user.id)
      insert_oauth_client()

      body = conn |> get("/api/oauth/clients") |> json_response(200)

      assert [%{"id" => id}] = body["data"]
      assert id == mine.id
    end
  end

  describe "GET/PATCH/DELETE /api/oauth/clients/:id" do
    test "another account's client is 404, not 403", %{conn: conn} do
      theirs = insert_oauth_client()

      assert conn |> get("/api/oauth/clients/#{theirs.id}") |> json_response(404)

      assert conn
             |> patch("/api/oauth/clients/#{theirs.id}", %{"name" => "x"})
             |> json_response(404)

      assert conn |> delete("/api/oauth/clients/#{theirs.id}") |> json_response(404)
    end

    test "updates the name and the URIs, never the client_id", %{conn: conn, user: user} do
      client = insert_oauth_client(user_id: user.id)

      body =
        conn
        |> patch("/api/oauth/clients/#{client.id}", %{
          "name" => "Renamed",
          "redirect_uris" => ["https://new.test/callback"]
        })
        |> json_response(200)

      assert body["name"] == "Renamed"
      assert body["client_id"] == client.client_id
      assert body["origins"] == ["https://new.test"]
    end

    test "cannot publish itself over the API", %{conn: conn, user: user} do
      client = insert_oauth_client(user_id: user.id)

      body =
        conn
        |> patch("/api/oauth/clients/#{client.id}", %{"published" => true, "name" => "x"})
        |> json_response(200)

      assert body["published"] == false
    end

    test "cannot alter an operator-published registration", %{conn: conn, user: user} do
      client = insert_oauth_client(user_id: user.id, published: true)

      body =
        conn
        |> patch("/api/oauth/clients/#{client.id}", %{"name" => "x"})
        |> json_response(422)

      assert body["errors"]["base"] == [
               "published clients can only be changed by an operator"
             ]
    end

    test "deletes", %{conn: conn, user: user} do
      client = insert_oauth_client(user_id: user.id)

      assert conn |> delete("/api/oauth/clients/#{client.id}") |> response(204)
      assert OAuth.list_clients(user.id) == []
    end

    test "cannot remove an operator-published registration", %{conn: conn, user: user} do
      client = insert_oauth_client(user_id: user.id, published: true)

      body = conn |> delete("/api/oauth/clients/#{client.id}") |> json_response(422)

      assert body["errors"]["base"] == [
               "published clients can only be removed by an operator"
             ]

      assert OAuth.get_client(client.client_id)
    end

    test "an id that is not a UUID is 404, not a cast error", %{conn: conn} do
      assert conn |> get("/api/oauth/clients/not-a-uuid") |> json_response(404)

      assert conn
             |> patch("/api/oauth/clients/not-a-uuid", %{"name" => "x"})
             |> json_response(404)

      assert conn |> delete("/api/oauth/clients/not-a-uuid") |> json_response(404)
    end
  end

  # A client is a standing way to obtain a full-scope key with one consent, so
  # the sandbox's per-conversation token must not be able to leave one behind
  # — the same argument that keeps API key management off the sprite scope.
  describe "scope" do
    test "a sprite-scoped key is refused on every route", %{conn: conn, user: user} do
      client = insert_oauth_client(user_id: user.id)
      {:ok, {_key, raw}} = Fountain.Accounts.create_api_key(user.id, "sprite", scopes: ["sprite"])

      conn = conn |> recycle() |> put_req_header("authorization", "Bearer #{raw}")

      assert conn |> get("/api/oauth/clients") |> json_response(403)
      assert conn |> post("/api/oauth/clients", %{"name" => "x"}) |> json_response(403)
      assert conn |> delete("/api/oauth/clients/#{client.id}") |> json_response(403)
    end
  end
end
