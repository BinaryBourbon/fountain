defmodule FountainWeb.SessionControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /login (legacy_new)" do
    test "renders login form", %{conn: conn} do
      conn = get(conn, ~p"/login")
      assert html_response(conn, 200) =~ "token"
    end
  end

  describe "POST /login (legacy_create)" do
    test "sets admin session with correct token", %{conn: conn} do
      token = Application.fetch_env!(:fountain, :admin_token)
      conn = post(conn, ~p"/login", %{token: token})
      assert redirected_to(conn) =~ "/"
    end

    test "re-renders form with error for wrong token", %{conn: conn} do
      conn = post(conn, ~p"/login", %{token: "wrong-token"})
      assert html_response(conn, 401) =~ "Invalid token"
    end
  end

  describe "POST /logout (legacy_delete)" do
    test "clears session and redirects", %{conn: conn} do
      conn = conn |> login() |> post(~p"/logout")
      assert redirected_to(conn) =~ "/"
    end
  end

  describe "conn_case helpers" do
    test "authed/1 sets Bearer authorization header", %{conn: conn} do
      authed_conn = authed(conn)
      [header] = Plug.Conn.get_req_header(authed_conn, "authorization")
      assert String.starts_with?(header, "Bearer ")
    end

    test "login/1 sets admin session flag", %{conn: conn} do
      logged_conn = login(conn)
      conn = get(logged_conn, ~p"/health")
      assert conn.status == 200
    end
  end
end
