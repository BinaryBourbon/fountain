defmodule FountainWeb.DeviceLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.OAuth

  describe "/device — the approval half of fountain auth login --device (#1305)" do
    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login" <> _}}} = live(conn, ~p"/device")
    end

    test "signed out with ?code=: login round-trips back to the confirmation screen", %{
      conn: conn
    } do
      # The normal case for the flow's primary audience: `fountain auth login
      # --device` opened this URL, but the browser has no console session yet.
      # The login must come back here — the CLI is polling and the code is
      # fifteen minutes from expiry — not land on the dashboard.
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      user = insert_verified_user(password: "correct horse battery")
      path = "/device?" <> URI.encode_query(code: user_code)

      conn = get(conn, path)
      assert redirected_to(conn) == "/auth/login"
      assert get_session(conn, :return_to) == path

      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(%{return_to: path})
        |> post("/auth/login", %{"email" => user.email, "password" => "correct horse battery"})

      assert redirected_to(conn) == path

      # Follow the redirect: the confirmation screen, code prefilled.
      {:ok, lv, html} = conn |> recycle() |> live(path)
      assert html =~ "Approve"
      assert html =~ user_code

      lv |> element("button", "Approve") |> render_click()
      assert {:ok, %{api_key: key}} = OAuth.poll_device_grant(device_code)
      assert key.user_id == user.id
    end

    test "typing the code leads to confirm, approve feeds the waiting poll", %{conn: conn} do
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      user = insert_verified_user()

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/device")
      assert html =~ "Code shown in your terminal"

      html = lv |> element("form") |> render_submit(%{"code" => user_code})
      assert html =~ user_code
      assert html =~ user.email

      html = lv |> element("button", "Approve") |> render_click()
      assert html =~ "Return to your terminal"

      assert {:ok, %{api_key: key}} = OAuth.poll_device_grant(device_code)
      assert key.user_id == user.id
    end

    test "arriving with ?code= skips the typing but not the decision", %{conn: conn} do
      {:ok, %{device_code: device_code, user_code: user_code}} = OAuth.start_device_grant()
      user = insert_verified_user()

      conn = login_user(conn, user)
      {:ok, lv, html} = live(conn, ~p"/device?#{[code: user_code]}")

      assert html =~ "Approve"
      assert {:error, :authorization_pending} = OAuth.poll_device_grant(device_code)

      lv |> element("button", "Deny") |> render_click()
      assert {:error, :access_denied} = OAuth.poll_device_grant(device_code)
    end

    test "a wrong code stays on the form with a flash", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/device")

      html = lv |> element("form") |> render_submit(%{"code" => "WRNG-CODE"})
      assert html =~ "Code not found"
      assert html =~ "Code shown in your terminal"
    end
  end
end
