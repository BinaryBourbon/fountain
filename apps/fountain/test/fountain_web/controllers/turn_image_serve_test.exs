defmodule FountainWeb.TurnImageServeTest do
  @moduledoc """
  Content negotiation and spec coverage on the turn-image routes (#578).

  The bearer route lived in the `:accepts_json` pipeline, so
  `plug :accepts, ["json"]` refused an image Accept header with 406 before the
  action ran: an endpoint returning PNG bytes worked only for a client that
  did not ask for an image. Browsers hid it on the session route because they
  append `*/*` to the Accept header they send for `<img>`.

  Tenant scoping and the serve-time media-type guard are covered in
  `cross_tenant_isolation_test.exs`; these are about reaching the action at
  all, and about the endpoint being discoverable once you do.
  """

  use FountainWeb.ConnCase, async: true

  @png <<137, 80, 78, 71>>

  setup %{conn: conn} do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent)
    turn = insert_turn(conv)

    {:ok, _} =
      Fountain.Conversations._unsafe_insert_turn_images(turn.id, [
        %{media_type: "image/png", data: @png}
      ])

    %{
      conn: conn,
      user: user,
      key: raw_key,
      path: "/conversations/#{conv.id}/turns/#{turn.id}/images/0"
    }
  end

  describe "bearer route — Accept negotiation" do
    # The regression. Pre-#578 this raised Phoenix.NotAcceptableError (406 in
    # prod) from the :accepts_json pipeline, before the controller ran.
    for accept <- ["image/png", "image/*", "image/avif,image/webp,image/*,*/*;q=0.8"] do
      test "serves the bytes with Accept: #{accept}", %{conn: conn, key: key, path: path} do
        conn =
          conn
          |> authed_with_key(key)
          |> put_req_header("accept", unquote(accept))
          |> get("/api" <> path)

        assert response(conn, 200) == @png
        assert Plug.Conn.get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      end
    end

    test "still serves with Accept: */* — the only header that worked before", %{
      conn: conn,
      key: key,
      path: path
    } do
      conn =
        conn
        |> authed_with_key(key)
        |> put_req_header("accept", "*/*")
        |> get("/api" <> path)

      assert response(conn, 200) == @png
    end

    test "keeps the nosniff and sandbox guards", %{conn: conn, key: key, path: path} do
      conn =
        conn
        |> authed_with_key(key)
        |> put_req_header("accept", "image/png")
        |> get("/api" <> path)

      assert response(conn, 200)
      assert Plug.Conn.get_resp_header(conn, "x-content-type-options") == ["nosniff"]

      assert Plug.Conn.get_resp_header(conn, "content-security-policy") == [
               "default-src 'none'; sandbox"
             ]
    end

    test "an unauthenticated request is refused, not served", %{conn: conn, path: path} do
      conn =
        conn
        |> put_req_header("accept", "image/png")
        |> get("/api" <> path)

      assert conn.status in [401, 403]
    end
  end

  describe "browser route — unchanged" do
    test "the session route still serves with a browser-shaped Accept header", %{
      conn: conn,
      user: user,
      path: path
    } do
      conn =
        conn
        |> login_user(user)
        |> put_req_header("accept", "image/avif,image/webp,image/apng,image/*,*/*;q=0.8")
        |> get(path)

      assert response(conn, 200) == @png
    end

    test "the session route is not reachable with only a bearer token", %{
      conn: conn,
      key: key,
      path: path
    } do
      conn = conn |> authed_with_key(key) |> get(path)

      # Session-authenticated: a bearer token is not a session, so this
      # redirects to login rather than serving.
      assert conn.status in [302, 401, 403]
    end
  end

  describe "OpenAPI coverage" do
    test "the bearer route is in the spec and the browser route is not" do
      paths = FountainWeb.ApiSpec.spec().paths

      assert %OpenApiSpex.Operation{} =
               paths["/api/conversations/{conversation_id}/turns/{turn_id}/images/{position}"].get

      refute Map.has_key?(
               paths,
               "/conversations/{conversation_id}/turns/{turn_id}/images/{position}"
             )
    end

    test "the operation documents image bytes, not JSON" do
      op =
        FountainWeb.ApiSpec.spec().paths[
          "/api/conversations/{conversation_id}/turns/{turn_id}/images/{position}"
        ].get

      assert Map.has_key?(op.responses[200].content, "image/*")
    end
  end
end
