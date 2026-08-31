defmodule FountainWeb.DeviceLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.OAuth

  describe "/device — the approval half of fountain auth login --device (#1305)" do
    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/auth/login" <> _}}} = live(conn, ~p"/device")
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
