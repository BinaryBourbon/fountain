defmodule FountainWeb.AdminLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Index — access control" do
    test "admin user can access /admin", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin")
      assert html =~ "Admin"
      assert html =~ "Users"
      # An installed extension's figure, rendered by the console from data
      # (ADR 0043). Buzz's own tile is asserted in the extension's suite.
      assert html =~ Fountain.ExtensionFixtures.Enabled.overview_label()
      # The tile's optional note and link, so the whole `{label, value, opts}`
      # shape is covered rather than just the label.
      assert html =~ "contributed by an extension"
    end

    test "regular user is redirected away from /admin", %{conn: conn} do
      user = insert_active_user()
      conn = login_user(conn, user)
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin")
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin")
      assert path =~ "/auth/login"
    end
  end

  describe "AdminLive.Index — funnel section" do
    test "renders stage tiles with counts and conversions", %{conn: conn} do
      admin = insert_admin()
      _unverified = insert_user()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Funnel"
      assert html =~ "Registered"
      assert html =~ "Verified"
      assert html =~ "Onboarded"
      assert html =~ "Activated"
      assert html =~ "Funded"
      # 2 registered, 1 verified → 50% conversion tile
      assert html =~ "50% of prev"
    end

    test "shows the stalled-verified breakdown", %{conn: conn} do
      admin = insert_admin()
      stalled = insert_active_user()
      insert_agent(user_id: stalled.id)
      insert_conversation(user_id: stalled.id)
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      # admin + stalled are both verified and neither has had a reply; the
      # conversation that never answered is a start, not an activation.
      assert html =~ "2 verified users have never had a reply"
      assert html =~ "started a conversation and got nothing back: 1"
      # One: `stalled` kept a second agent beside the starter every verified
      # account owns (ADR 0038); the admin has only the starter (#1421).
      assert html =~ "built their own agent: 1"
      assert html =~ "added a credential: 0"
    end

    test "shows time to first reply", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Time to first reply"
      assert html =~ "No account has had a reply yet."

      user = insert_active_user()

      Fountain.Repo.update!(
        Ecto.Changeset.change(user,
          email_verified_at:
            DateTime.utc_now() |> DateTime.add(-48, :hour) |> DateTime.truncate(:second)
        )
      )

      insert_turn(insert_conversation(user_id: user.id), %{
        status: "completed",
        reply_text: "the agent answered",
        ended_at: DateTime.utc_now() |> DateTime.add(-46, :hour) |> DateTime.truncate(:second)
      })

      {:ok, _lv, html} = live(conn, ~p"/admin")

      assert html =~ "Time to first reply"
      assert html =~ "median"
      assert html =~ "p90"
      assert html =~ "2h"
      assert html =~ "within a day of verifying: 1 of"
    end
  end
end
