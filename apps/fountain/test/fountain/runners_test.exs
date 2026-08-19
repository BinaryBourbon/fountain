defmodule Fountain.RunnersTest do
  use Fountain.DataCase, async: true

  alias Fountain.Runners
  alias Fountain.Runners.FakeDaemon

  describe "register/3" do
    test "the first connection of a name inserts a row and audits it" do
      user = insert_verified_user()

      assert {:ok, runner} =
               Runners.register(user.id, %{
                 "name" => "mini",
                 "hostname" => "mini.local",
                 "os" => "darwin",
                 "arch" => "arm64",
                 "version" => "v0.13.0",
                 "root" => "/Users/jake/.fountain/runners/mini"
               })

      assert runner.user_id == user.id
      assert runner.name == "mini"
      assert runner.connected_at
      assert runner.last_seen_at

      actions = user.id |> Fountain.Audit.list_recent_for_user(10) |> Enum.map(& &1.action)
      assert "runner.registered" in actions
    end

    test "a reconnect refreshes the same row silently" do
      user = insert_verified_user()
      {:ok, first} = Runners.register(user.id, %{"name" => "mini", "os" => "darwin"})
      {:ok, second} = Runners.register(user.id, %{"name" => "mini", "os" => "linux"})

      assert first.id == second.id
      assert second.os == "linux"
      assert [%{name: "mini"}] = Runners.list_runners(user.id)

      registered =
        user.id
        |> Fountain.Audit.list_recent_for_user(10)
        |> Enum.count(&(&1.action == "runner.registered"))

      assert registered == 1
    end

    test "names are validated" do
      user = insert_verified_user()
      assert {:error, changeset} = Runners.register(user.id, %{"name" => "Not Valid!"})
      assert %{name: [_]} = errors_on(changeset)
    end

    test "names are unique per user, not globally" do
      a = insert_verified_user()
      b = insert_verified_user()
      assert {:ok, _} = Runners.register(a.id, %{"name" => "mini"})
      assert {:ok, _} = Runners.register(b.id, %{"name" => "mini"})
      assert [_] = Runners.list_runners(a.id)
      assert [_] = Runners.list_runners(b.id)
    end
  end

  describe "tenant scoping" do
    test "get_runner/2 and delete_runner/2 are scoped to the owner" do
      owner = insert_verified_user()
      other = insert_verified_user()
      {:ok, runner} = Runners.register(owner.id, %{"name" => "mini"})

      assert Runners.get_runner(runner.id, owner.id)
      refute Runners.get_runner(runner.id, other.id)

      assert {:ok, _} = Runners.delete_runner(runner)
      refute Runners.get_runner(runner.id, owner.id)

      actions = owner.id |> Fountain.Audit.list_recent_for_user(10) |> Enum.map(& &1.action)
      assert "runner.deleted" in actions
    end
  end

  describe "online status and placement" do
    test "a runner is online exactly while a connection is registered" do
      user = insert_verified_user()
      {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
      refute Runners.online?(runner)
      assert {:error, :no_runner_online} = Runners.pick_runner(user.id)
      assert {:error, :no_runner_online} = Runners.mint_sandbox_name(user.id)

      {:ok, daemon} = FakeDaemon.start(runner.id, user.id, name: "mini")
      assert Runners.online?(runner)
      assert {:ok, %{id: picked}} = Runners.pick_runner(user.id)
      assert picked == runner.id
      assert [%{online: true}] = Runners.list_runners_with_status(user.id)
      assert {runner.id, user.id} in Runners.online_runner_ids()

      FakeDaemon.stop(daemon)
      refute Runners.online?(runner)
    end

    test "the most recently connected online runner wins" do
      user = insert_verified_user()
      {:ok, old} = Runners.register(user.id, %{"name" => "old"})
      {:ok, new} = Runners.register(user.id, %{"name" => "new"})

      # Both online; `new` connected later (same second is possible, so pin it).
      Repo.update_all(from(r in Runners.Runner, where: r.id == ^old.id),
        set: [connected_at: DateTime.add(new.connected_at, -60, :second)]
      )

      {:ok, d1} = FakeDaemon.start(old.id, user.id, name: "old")
      {:ok, d2} = FakeDaemon.start(new.id, user.id, name: "new")

      on_exit(fn ->
        FakeDaemon.stop(d1)
        FakeDaemon.stop(d2)
      end)

      assert {:ok, %{id: id}} = Runners.pick_runner(user.id)
      assert id == new.id

      assert {:ok, name} = Runners.mint_sandbox_name(user.id)
      assert {:ok, ^id} = Runners.parse_sandbox_name(name)
    end

    test "a second connection for the same runner is refused" do
      user = insert_verified_user()
      {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
      {:ok, d1} = FakeDaemon.start(runner.id, user.id, name: "mini")
      on_exit(fn -> FakeDaemon.stop(d1) end)

      Process.flag(:trap_exit, true)
      assert {:error, :normal} = FakeDaemon.start(runner.id, user.id, name: "mini")
    end

    test "deleting a runner disconnects its live socket" do
      user = insert_verified_user()
      {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
      {:ok, %{socket: socket}} = FakeDaemon.start(runner.id, user.id, name: "mini")
      Process.unlink(socket)
      ref = Process.monitor(socket)

      {:ok, _} = Runners.delete_runner(runner)
      assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
      refute Runners.online?(runner)
    end
  end

  describe "sandbox names" do
    test "round-trip the runner id" do
      id = Ecto.UUID.generate()
      name = Runners.sandbox_name_for(id)
      assert String.starts_with?(name, "runner-")
      assert {:ok, ^id} = Runners.parse_sandbox_name(name)
    end

    test "reject other providers' names" do
      assert :error = Runners.parse_sandbox_name("fountain-abcd1234-deadbeef")
      assert :error = Runners.parse_sandbox_name("runner-short-x")

      assert :error =
               Runners.parse_sandbox_name("runner-zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz-abcd1234")
    end
  end
end
