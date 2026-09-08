defmodule FountainWeb.AdminInferenceChatGPTLiveTest do
  @moduledoc """
  The "ChatGPT account (codex)" row on `/admin/inference` (ADR 0047): the
  four states it renders, and the three ways in — paste, workspace token,
  device code — plus Disconnect. `async: false`: one platform row, and the
  device flow runs in a supervised task that needs the shared SQL sandbox.
  """

  use FountainWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Fountain.ChatGPTFixtures
  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Audit.AdminEvent
  alias Fountain.PlatformChatGPT
  alias Fountain.Repo

  setup do
    stub(%{})
    admin = insert_active_user()
    {:ok, admin} = Accounts.update_user_role(admin, "admin")
    %{admin: admin}
  end

  defp open(conn, admin) do
    conn = login_user(conn, admin)
    live(conn, ~p"/admin/inference")
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end

  describe "the four states" do
    test "not connected", %{conn: conn, admin: admin} do
      {:ok, _lv, html} = open(conn, admin)
      assert html =~ "ChatGPT account (codex)"
      assert html =~ "not connected"
      refute html =~ "Disconnect"
    end

    test "connected shows who, the plan, and the renewal", %{conn: conn, admin: admin} do
      connect!(%{actor_user_id: admin.id})
      {:ok, _lv, html} = open(conn, admin)
      assert html =~ "Connected as"
      assert html =~ "admin@example.com"
      assert html =~ "(pro)"
      assert html =~ admin.email
      assert html =~ "Last renewed"
      assert html =~ ~s(>connected</span>) or html =~ "connected\n"
      assert html =~ "Disconnect"
      refute html =~ "rt_original"
    end

    test "revoked names the reason", %{conn: conn, admin: admin} do
      connect!(%{access_token: access_token(1)})
      stub_refusal("refresh_token_expired")
      assert {:error, :revoked} = PlatformChatGPT.access_token()

      {:ok, _lv, html} = open(conn, admin)
      assert html =~ "Sign-in lost"
      assert html =~ "refresh_token_expired"
      assert html =~ "revoked"
    end

    test "expired", %{conn: conn, admin: admin} do
      {:ok, _} = PlatformChatGPT.connect_workspace_token("wst_x", ~D[2020-01-01])
      assert {:error, :expired} = PlatformChatGPT.access_token()

      {:ok, _lv, html} = open(conn, admin)
      assert html =~ "The token expired"
      assert html =~ "expired"
    end
  end

  describe "paste" do
    test "connects and flashes who", %{conn: conn, admin: admin} do
      {:ok, lv, _} = open(conn, admin)

      html = render_submit(lv, "chatgpt_paste", %{"auth_json" => auth_json()})
      assert html =~ "ChatGPT account connected as admin@example.com"
      assert html =~ "Connected as"

      assert [event] =
               Repo.all(
                 from e in AdminEvent, where: e.event_type == "admin.platform_chatgpt.connected"
               )

      assert event.actor_user_id == admin.id
      assert event.metadata["method"] == "paste"
    end

    test "says why a file is refused", %{conn: conn, admin: admin} do
      {:ok, lv, _} = open(conn, admin)

      html =
        render_submit(lv, "chatgpt_paste", %{"auth_json" => auth_json(%{auth_mode: "apiKey"})})

      assert html =~ "API-key login, not a ChatGPT sign-in"

      html = render_submit(lv, "chatgpt_paste", %{"auth_json" => "nope"})
      assert html =~ "not an auth.json codex wrote"
      refute PlatformChatGPT.active?()
    end
  end

  describe "workspace token" do
    test "saves with its expiry and account id", %{conn: conn, admin: admin} do
      {:ok, lv, _} = open(conn, admin)

      html =
        render_submit(lv, "chatgpt_workspace_token", %{
          "value" => "wst_workspace",
          "expires_on" => "2031-06-30",
          "account_id" => "acct_ws"
        })

      assert html =~ "Workspace access token saved"
      assert html =~ "workspace token"
      assert html =~ "acct_ws"
      refute html =~ "wst_workspace"

      assert %{kind: "workspace_token", access_expires_at: ~U[2031-06-30 23:59:59Z]} =
               PlatformChatGPT.status()
    end

    test "refuses a token with spaces", %{conn: conn, admin: admin} do
      {:ok, lv, _} = open(conn, admin)
      html = render_submit(lv, "chatgpt_workspace_token", %{"value" => "not a token"})
      assert html =~ "one token with no spaces"
    end
  end

  describe "disconnect" do
    test "returns the row to not connected and records", %{conn: conn, admin: admin} do
      connect!()
      {:ok, lv, _} = open(conn, admin)

      html = render_click(lv, "chatgpt_disconnect", %{})
      assert html =~ "ChatGPT account disconnected"
      assert html =~ "not connected"
      assert PlatformChatGPT.status() == :not_connected

      assert [_] =
               Repo.all(
                 from e in AdminEvent,
                   where: e.event_type == "admin.platform_chatgpt.disconnected"
               )
    end
  end

  describe "device code (gate 3)" do
    test "shows the code, then connects when the server says approved", %{
      conn: conn,
      admin: admin
    } do
      stub(%{
        "/api/accounts/deviceauth/usercode" => fn %{"client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"} ->
          {200, %{"user_code" => "ABCD-1234", "device_auth_id" => "dev_1", "interval" => 0}}
        end,
        "/api/accounts/deviceauth/token" => fn %{
                                                 "device_auth_id" => "dev_1",
                                                 "user_code" => "ABCD-1234"
                                               } ->
          {200, %{"authorization_code" => "code_1", "code_verifier" => "ver_1"}}
        end,
        "/oauth/token" => fn %{"grant_type" => "authorization_code", "code" => "code_1"} = body ->
          assert body["code_verifier"] == "ver_1"
          assert body["redirect_uri"] == "https://auth.openai.com/deviceauth/callback"

          {200,
           %{
             "access_token" => access_token(),
             "refresh_token" => "rt_from_device",
             "id_token" => id_token(%{email: "device@example.com"})
           }}
        end
      })

      {:ok, lv, _} = open(conn, admin)
      render_click(lv, "chatgpt_connect_device", %{})

      assert eventually(fn -> render(lv) =~ "Connected as" end)
      html = render(lv)
      assert html =~ "device@example.com"
      assert %{status: "active", account_email: "device@example.com"} = PlatformChatGPT.status()

      assert [event] =
               Repo.all(
                 from e in AdminEvent, where: e.event_type == "admin.platform_chatgpt.connected"
               )

      assert event.metadata["method"] == "device_code"
      assert event.actor_user_id == admin.id
    end

    test "shows the code while waiting, and the failure when the server refuses", %{
      conn: conn,
      admin: admin
    } do
      test_pid = self()

      stub(%{
        "/api/accounts/deviceauth/usercode" => fn _ ->
          # A one-second interval, so the page holds the code long enough to see.
          {200, %{"user_code" => "WXYZ-9876", "device_auth_id" => "dev_2", "interval" => 1}}
        end,
        "/api/accounts/deviceauth/token" => fn _ ->
          # Pending once, so the page renders the code, then a hard refusal.
          case Process.get(:polls, 0) do
            0 ->
              Process.put(:polls, 1)
              send(test_pid, :polled_once)
              {403, %{}}

            _ ->
              {400, %{"error" => "access_denied"}}
          end
        end
      })

      {:ok, lv, _} = open(conn, admin)
      render_click(lv, "chatgpt_connect_device", %{})

      assert eventually(fn -> render(lv) =~ "WXYZ-9876" end)
      assert render(lv) =~ "codex/device"
      assert eventually(fn -> render(lv) =~ "Device sign-in failed" end)
      refute PlatformChatGPT.active?()
    end
  end
end
