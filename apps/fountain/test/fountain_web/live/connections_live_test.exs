defmodule FountainWeb.ConnectionsLiveTest do
  # Flips the broker ratchet (global app env).
  use FountainWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Fountain.BrokerTestHelpers

  alias Fountain.Connections
  alias Fountain.Connections.Google

  test "hidden and redirected for an account the broker is not on for", %{conn: conn} do
    user = insert_verified_user()
    enable_broker_for([])
    conn = login_user(conn, user)

    refute conn |> get(~p"/account") |> html_response(200) =~ ~s(href="/account/connections")
    assert {:error, {:live_redirect, %{to: "/account"}}} = live(conn, ~p"/account/connections")
  end

  test "lists connections, links to the flow, revokes and removes", %{conn: conn} do
    user = insert_verified_user()
    enable_broker_for([user.id])
    c = insert_connection(user, account_email: "me@example.com", access_token: "never-in-html")
    conn = login_user(conn, user)

    assert conn |> get(~p"/account") |> html_response(200) =~ ~s(href="/account/connections")

    {:ok, lv, html} = live(conn, ~p"/account/connections")
    assert html =~ "me@example.com"
    assert html =~ ~s(href="/connections/google/start")
    assert html =~ c.id
    assert html =~ "GOOGLE_ACCESS_TOKEN"
    refute html =~ "never-in-html"

    Req.Test.stub(Google, fn req -> Req.Test.json(req, %{}) end)

    html = lv |> element("#connection-#{c.id} button", "Revoke") |> render_click()
    assert html =~ "Revoked me@example.com"
    assert %{status: "revoked"} = Connections.get_connection(c.id, user.id)
    assert html =~ "Connect the account again"

    html = lv |> element("#connection-#{c.id} button", "Remove") |> render_click()
    assert html =~ "No connections yet"
    refute Connections.get_connection(c.id, user.id)
  end

  test "says so when Google is not configured on this deployment", %{conn: conn} do
    user = insert_verified_user()
    enable_broker_for([user.id])
    previous = Application.get_env(:fountain, :google_oauth_client_id)
    on_exit(fn -> Application.put_env(:fountain, :google_oauth_client_id, previous) end)
    Application.put_env(:fountain, :google_oauth_client_id, nil)

    {:ok, _lv, html} = conn |> login_user(user) |> live(~p"/account/connections")
    assert html =~ "Not configured on this deployment"
    refute html =~ ~s(href="/connections/google/start")
  end
end
