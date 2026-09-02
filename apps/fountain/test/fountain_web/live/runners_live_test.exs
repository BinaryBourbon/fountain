defmodule FountainWeb.RunnersLiveTest do
  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Runners
  alias Managoat.Runner.FakeDaemon

  test "lists runners with live status and forgets one", %{conn: conn} do
    user = insert_verified_user()
    {:ok, offline} = Runners.register(user.id, %{"name" => "laptop", "hostname" => "lap.local"})

    {:ok, online} =
      Runners.register(user.id, %{"name" => "mini", "os" => "darwin", "arch" => "arm64"})

    {:ok, daemon} = FakeDaemon.start(online.id, meta: %{user_id: user.id}, name: "mini")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    conn = login_user(conn, user)
    {:ok, lv, html} = live(conn, ~p"/account/runners")

    assert html =~ "laptop"
    assert html =~ "lap.local"
    assert html =~ "mini"
    assert html =~ "darwin · arm64"
    assert html =~ "online"
    assert html =~ "fountain runner"

    lv |> element("#runner-#{offline.id} button", "Forget") |> render_click()
    refute Runners.get_runner(offline.id, user.id)
    refute render(lv) =~ "lap.local"
  end

  test "shows the empty state and the start instructions", %{conn: conn} do
    user = insert_verified_user()
    {:ok, _lv, html} = conn |> login_user(user) |> live(~p"/account/runners")
    assert html =~ "No runner has connected yet"
  end

  test "unauthenticated user is redirected to login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/auth/login"}}} = live(conn, ~p"/account/runners")
  end
end
