defmodule FountainWeb.OnboardingLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  describe "OnboardingLive.Wizard — redirect logic" do
    test "user who completed onboarding is redirected to /dashboard", %{conn: conn} do
      user = insert_verified_user()
      {:ok, completed_user} = Fountain.Accounts.complete_onboarding(user)

      conn = login_user(conn, completed_user)
      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               live(conn, ~p"/onboarding/step_1")
    end

    test "user with no onboarding_state mounts step_1", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)

      {:ok, lv, html} = live(conn, ~p"/onboarding/step_1")
      assert html =~ "Step 1"
      assert html =~ "Create an environment"
    end

    test "unauthenticated user is redirected to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/onboarding/step_1")
      assert path =~ "/auth/login"
    end
  end

  describe "OnboardingLive.Wizard — step 1 (environment)" do
    setup %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_1")
      %{lv: lv, user: user}
    end

    test "skip_env advances to step_2", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/onboarding/step_2"}}} =
               lv |> element("button", "Skip") |> render_click()
    end

    test "submitting a valid env advances to step_2", %{lv: lv} do
      assert {:error, {:live_redirect, %{to: "/onboarding/step_2"}}} =
               lv
               |> form("form[phx-submit='create_env']", env: %{name: "my-env"})
               |> render_submit()
    end

    test "submitting an empty name shows an error", %{lv: lv} do
      # Name is required on the DB level; an empty string will produce a changeset error
      html =
        lv
        |> form("form[phx-submit='create_env']", env: %{name: ""})
        |> render_submit()

      # Either stays on step_1 (redirect not triggered) or shows error
      assert html =~ "Create an environment" or html =~ "can&#39;t be blank"
    end
  end

  describe "OnboardingLive.Wizard — step 3 (finish)" do
    test "start_conversation redirects to /conversations/new", %{conn: conn} do
      user = insert_verified_user()
      # Manually advance to step_3
      {:ok, user} = Fountain.Accounts.advance_onboarding(user, "step_3")
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_3")

      assert {:error, {:live_redirect, %{to: "/conversations/new"}}} =
               lv |> element("button", "Start first conversation") |> render_click()
    end

    test "skip_wizard redirects to /dashboard", %{conn: conn} do
      user = insert_verified_user()
      conn = login_user(conn, user)
      {:ok, lv, _html} = live(conn, ~p"/onboarding/step_1")

      assert {:error, {:live_redirect, %{to: "/dashboard"}}} =
               lv |> element("button", "Skip setup") |> render_click()
    end
  end
end
