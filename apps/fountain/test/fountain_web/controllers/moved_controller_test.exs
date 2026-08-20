defmodule FountainWeb.MovedControllerTest do
  @moduledoc """
  The paths the retired pages left behind (#867).

  `/conversations`, `/team` and `/onboarding` were LiveViews. They are in sent
  emails, filed support issues, agents' skills and bookmarks, so they redirect
  instead of 404ing — to the app that took the page over, or, where the
  deployment has no such app, to somewhere inside Fountain.
  """

  use FountainWeb.ConnCase, async: false

  setup %{conn: conn} do
    user = insert_verified_user()

    original = {
      Application.fetch_env(:fountain, :conversations_app_url),
      Application.fetch_env(:fountain, :team_app_url)
    }

    on_exit(fn ->
      case original do
        {{:ok, c}, {:ok, t}} ->
          Application.put_env(:fountain, :conversations_app_url, c)
          Application.put_env(:fountain, :team_app_url, t)

        _ ->
          Application.delete_env(:fountain, :conversations_app_url)
          Application.delete_env(:fountain, :team_app_url)
      end
    end)

    {:ok, conn: login_user(conn, user), user: user}
  end

  describe "with the apps configured" do
    setup do
      Application.put_env(:fountain, :conversations_app_url, "https://apps.test/convs/")
      Application.put_env(:fountain, :team_app_url, "https://apps.test/team/")
      :ok
    end

    test "the conversation list", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/conversations"), 302) == "https://apps.test/convs/"
    end

    test "starting one", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/conversations/new"), 302) ==
               "https://apps.test/convs/#/new"
    end

    test "one conversation, and its raw log", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/conversations/abc123"), 302) ==
               "https://apps.test/convs/#/c/abc123"

      assert redirected_to(get(conn, ~p"/conversations/abc123/logs"), 302) ==
               "https://apps.test/convs/#/c/abc123/logs"
    end

    test "the team roster, and one teammate", %{conn: conn} do
      assert redirected_to(get(conn, ~p"/team"), 302) == "https://apps.test/team/"

      assert redirected_to(get(conn, ~p"/team/agent-1"), 302) ==
               "https://apps.test/team/#/team/agent-1"
    end

    test "onboarding was not replaced by an app — the dashboard says what is missing", %{
      conn: conn
    } do
      assert redirected_to(get(conn, ~p"/onboarding"), 302) == "/dashboard"
      assert redirected_to(get(conn, ~p"/onboarding/step_1"), 302) == "/dashboard"
    end
  end

  describe "with no app configured" do
    setup do
      Application.put_env(:fountain, :conversations_app_url, "")
      Application.put_env(:fountain, :team_app_url, "")
      :ok
    end

    test "the reader stays inside Fountain rather than being sent nowhere", %{conn: conn} do
      for path <- [
            ~p"/conversations",
            ~p"/conversations/new",
            ~p"/conversations/abc123",
            ~p"/conversations/abc123/logs",
            ~p"/team",
            ~p"/team/agent-1"
          ] do
        assert redirected_to(get(conn, path), 302) == "/dashboard", "#{path} went somewhere else"
      end
    end
  end

  test "they are behind the session, like the pages they replaced", %{conn: _conn} do
    conn = build_conn()

    for path <- [~p"/conversations", ~p"/team", ~p"/onboarding"] do
      assert redirected_to(get(conn, path), 302) =~ "/auth/login"
    end
  end
end
