defmodule FountainWeb.ConnectionsControllerTest do
  # Flips the broker ratchet (global app env).
  use FountainWeb.ConnCase, async: false

  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.Google

  setup %{conn: conn} do
    user = insert_verified_user()
    enable_broker_for([user.id])
    {:ok, conn: login_user(conn, user), user: user}
  end

  test "start sends the browser to Google with offline access and a signed state", %{conn: conn} do
    conn = get(conn, ~p"/connections/google/start")
    assert redirected_to(conn) =~ "https://accounts.google.com/o/oauth2/v2/auth?"

    params = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["access_type"] == "offline"
    assert params["prompt"] == "consent"
    assert params["client_id"] == "google-test-client-id"
    assert params["redirect_uri"] =~ "/connections/google/callback"
    assert is_binary(params["state"])
    assert get_session(conn, :connections_oauth_nonce)
  end

  test "the round trip stores a connection on the signed-in account", %{conn: conn, user: user} do
    conn = get(conn, ~p"/connections/google/start")
    state = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    Req.Test.stub(Google, fn req ->
      case req.request_path do
        "/token" ->
          {:ok, body, _} = Plug.Conn.read_body(req)
          form = URI.decode_query(body)
          assert form["grant_type"] == "authorization_code"
          assert form["code"] == "the-code"
          assert form["client_secret"] == "google-test-client-secret"

          Req.Test.json(req, %{
            "access_token" => "at-1",
            "refresh_token" => "rt-1",
            "expires_in" => 3599,
            "scope" => "openid email https://www.googleapis.com/auth/gmail.modify"
          })

        "/v1/userinfo" ->
          assert Plug.Conn.get_req_header(req, "authorization") == ["Bearer at-1"]
          Req.Test.json(req, %{"email" => "jake@example.com", "email_verified" => true})
      end
    end)

    conn =
      conn
      |> recycle()
      |> get(~p"/connections/google/callback", %{"code" => "the-code", "state" => state})

    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Connected jake@example.com"

    assert [%{account_email: "jake@example.com", status: "active", scopes: scopes}] =
             Connections.list_connections(user.id)

    assert "https://www.googleapis.com/auth/gmail.modify" in scopes
    refute get_session(conn, :connections_oauth_nonce)
  end

  test "a callback whose state did not come from this session is refused", %{conn: conn, user: user} do
    state = Phoenix.Token.sign(FountainWeb.Endpoint, "connections:oauth_state", {user.id, "other"})
    Req.Test.stub(Google, fn _ -> flunk("no exchange for a bad state") end)

    conn = get(conn, ~p"/connections/google/callback", %{"code" => "c", "state" => state})
    assert redirected_to(conn) == ~p"/account/connections"
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "did not start from this session"
    assert Connections.list_connections(user.id) == []
  end

  test "a consent Google answered without a refresh token is explained", %{conn: conn, user: user} do
    conn = get(conn, ~p"/connections/google/start")
    state = conn |> redirected_to() |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    Req.Test.stub(Google, fn req ->
      Req.Test.json(req, %{"access_token" => "at", "expires_in" => 10})
    end)

    conn = conn |> recycle() |> get(~p"/connections/google/callback", %{"code" => "c", "state" => state})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "no refresh token"
    assert Connections.list_connections(user.id) == []
  end

  test "a denied consent comes back as a flash", %{conn: conn} do
    conn = get(conn, ~p"/connections/google/callback", %{"error" => "access_denied"})
    assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "access_denied"
  end

  test "an account the broker is not on for is sent to /account", %{conn: conn} do
    Application.put_env(:fountain, :broker_tenants, [])
    conn = get(conn, ~p"/connections/google/start")
    assert redirected_to(conn) == ~p"/account"
  end

  test "signed out, the flow is not reachable" do
    conn = build_conn() |> get(~p"/connections/google/start")
    assert redirected_to(conn) =~ "/auth/login"
  end
end
