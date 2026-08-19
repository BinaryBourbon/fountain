defmodule FountainWeb.RunnerControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Runners
  alias Fountain.Runners.FakeDaemon

  setup %{conn: conn} do
    user = insert_verified_user()
    {_record, raw_key} = insert_api_key(user)
    %{conn: authed_with_key(conn, raw_key), user: user}
  end

  describe "GET /api/runners" do
    test "lists the user's runners with live online status", %{conn: conn, user: user} do
      {:ok, offline} = Runners.register(user.id, %{"name" => "laptop", "os" => "darwin"})
      {:ok, online} = Runners.register(user.id, %{"name" => "mini", "hostname" => "mini.local"})
      {:ok, daemon} = FakeDaemon.start(online.id, user.id, name: "mini")
      on_exit(fn -> FakeDaemon.stop(daemon) end)

      other = insert_verified_user()
      {:ok, _} = Runners.register(other.id, %{"name" => "theirs"})

      %{"data" => data} = conn |> get("/api/runners") |> json_response(200)
      by_name = Map.new(data, &{&1["name"], &1})

      assert Map.keys(by_name) |> Enum.sort() == ["laptop", "mini"]
      assert by_name["mini"]["online"] == true
      assert by_name["mini"]["hostname"] == "mini.local"
      assert by_name["mini"]["id"] == online.id
      assert by_name["laptop"]["online"] == false
      assert by_name["laptop"]["id"] == offline.id
    end
  end

  describe "DELETE /api/runners/:id" do
    test "forgets the runner", %{conn: conn, user: user} do
      {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
      assert conn |> delete("/api/runners/#{runner.id}") |> response(204)
      refute Runners.get_runner(runner.id, user.id)
    end

    test "is scoped to the owner", %{conn: conn} do
      other = insert_verified_user()
      {:ok, runner} = Runners.register(other.id, %{"name" => "mini"})
      assert conn |> delete("/api/runners/#{runner.id}") |> json_response(404)
      assert Runners.get_runner(runner.id, other.id)
    end
  end

  describe "GET /api/runners/ws" do
    test "refuses a plain HTTP request without registering anything", %{conn: conn, user: user} do
      # runners_enabled is off in test config: the very first answer is that.
      assert %{"error" => "runners_disabled"} =
               conn |> get("/api/runners/ws", %{"name" => "mini"}) |> json_response(404)

      assert Runners.list_runners(user.id) == []
    end

    test "requires a full-scope key", %{user: user} do
      {_record, sprite_key} = insert_api_key(user, "sprite", scopes: ["sprite"])

      conn =
        build_conn()
        |> authed_with_key(sprite_key)
        |> get("/api/runners/ws", %{"name" => "mini"})

      assert json_response(conn, 403)
    end
  end
end
