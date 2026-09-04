defmodule FountainBuzz.ManagerTest do
  # async: false — starts real harness processes under the global Horde
  # supervisor, and DataCase gives shared-mode DB so their terminate-time key
  # revocation reaches this connection.
  use Fountain.DataCase, async: false
  import FountainBuzz.Factory

  import Ecto.Query

  alias Fountain.Accounts.ApiKey
  alias FountainBuzz.Manager
  alias Fountain.Repo

  setup do
    dir = Fountain.TmpDir.mkdir!("buzz-mgr")
    fake = Path.join(dir, "buzz-acp")
    FountainBuzz.TestSupport.write_fake_acp!(fake)

    on_exit(fn ->
      # Tear down every harness this test left running (no prod harnesses exist
      # under this supervisor in the test node) before the tmp dir goes away.
      FountainBuzz.TestSupport.stop_all_harnesses!()

      File.rm_rf(dir)
    end)

    %{fake: fake}
  end

  defp launch_opts(fake), do: [buzz_acp_path: fake, base_url: "https://fountain.test"]

  defp active_keys(user_id) do
    Repo.all(
      from k in ApiKey,
        where: k.user_id == ^user_id and is_nil(k.revoked_at) and like(k.name, "buzz-acp:%")
    )
  end

  defp active_key_count(user_id) do
    Repo.one(
      from k in ApiKey,
        where: k.user_id == ^user_id and is_nil(k.revoked_at) and like(k.name, "buzz-acp:%"),
        select: count(k.id)
    )
  end

  test "start_harness stands a harness up and registers it", %{fake: fake} do
    identity = insert_buzz_identity()

    assert {:ok, pid} = Manager.start_harness(identity, launch_opts(fake))
    assert is_pid(pid)
    assert Manager.running?(identity.id)
    assert Manager.whereis(identity.id) == pid
    assert active_key_count(identity.user_id) == 1

    Manager.stop_harness(identity.id)
  end

  test "running_count counts registered harnesses cluster-wide", %{fake: fake} do
    baseline = Manager.running_count()
    first = insert_buzz_identity()
    second = insert_buzz_identity()

    assert {:ok, _pid} = Manager.start_harness(first, launch_opts(fake))
    assert {:ok, _pid} = Manager.start_harness(second, launch_opts(fake))
    assert Manager.running_count() == baseline + 2

    # `stop_harness/1` returns once the process is down, but the registry drops
    # the entry by monitor a moment later, so the count here raced it and
    # periodically read 2 (#1544). `await_stopped/2` is the same wait
    # `restart_harness/2` uses for the same reason.
    Manager.stop_harness(first.id)
    Manager.await_stopped(first.id)
    assert Manager.running_count() == baseline + 1
    Manager.stop_harness(second.id)
  end

  test "start_harness is idempotent and mints no second credential", %{fake: fake} do
    identity = insert_buzz_identity()

    assert {:ok, pid} = Manager.start_harness(identity, launch_opts(fake))
    assert {:ok, ^pid} = Manager.start_harness(identity, launch_opts(fake))
    # The second call short-circuits on `whereis` before minting anything.
    assert active_key_count(identity.user_id) == 1

    Manager.stop_harness(identity.id)
  end

  test "stop_harness terminates the harness and revokes its launch key", %{fake: fake} do
    identity = insert_buzz_identity()

    {:ok, _pid} = Manager.start_harness(identity, launch_opts(fake))
    assert active_key_count(identity.user_id) == 1

    :ok = Manager.stop_harness(identity.id)
    Manager.await_stopped(identity.id)

    refute Manager.running?(identity.id)
    # terminate_child is synchronous, so the harness's on_stop (key revoke) has
    # already run by the time it returns — that part needs no wait. It is the
    # registry that lags, which is what the line above waits for (#1544).
    assert active_key_count(identity.user_id) == 0
  end

  # #790: a converging deploy that changes the author gate (or any launch field)
  # must bounce the harness — a running one keeps the env it started with.
  test "restart_harness bounces a running harness onto a fresh launch", %{fake: fake} do
    identity = insert_buzz_identity()

    {:ok, old_pid} = Manager.start_harness(identity, launch_opts(fake))
    [old_key] = active_keys(identity.user_id)

    {:ok, identity} = FountainBuzz.update_identity(identity, %{"respond_to" => "anyone"})
    assert {:ok, new_pid} = Manager.restart_harness(identity, launch_opts(fake))

    assert is_pid(new_pid)
    assert new_pid != old_pid
    refute Process.alive?(old_pid)
    assert Manager.whereis(identity.id) == new_pid

    # The old launch key was revoked by the stop; exactly one fresh key is live.
    assert [new_key] = active_keys(identity.user_id)
    assert new_key.id != old_key.id

    Manager.stop_harness(identity.id)
  end

  test "restart_harness with nothing running is just a start", %{fake: fake} do
    identity = insert_buzz_identity()

    assert {:ok, pid} = Manager.restart_harness(identity, launch_opts(fake))
    assert Manager.whereis(identity.id) == pid
    assert active_key_count(identity.user_id) == 1

    Manager.stop_harness(identity.id)
  end

  test "stop_harness is a no-op when nothing is running" do
    identity = insert_buzz_identity()
    assert Manager.stop_harness(identity.id) == :ok
    refute Manager.running?(identity.id)
  end

  test "start_harness surfaces a launch error and leaks no key", %{fake: _fake} do
    identity = insert_buzz_identity()

    # No binary path and none in config → harness_launch refuses before minting.
    assert {:error, :no_buzz_acp_path} =
             Manager.start_harness(identity, base_url: "https://fountain.test")

    assert active_key_count(identity.user_id) == 0
    refute Manager.running?(identity.id)
  end

  describe "the launch is resolved by the child's start, not frozen in the spec" do
    # Horde replays a stored child spec on every deploy, node loss and rebalance.
    # If the spec carried the launch, a replay would reuse a launcher path from a
    # previous release and an API key the old node revoked in terminate/2 —
    # which is exactly what took the FizzTheShark harness down on 2026-08-16.
    # `start_harness_link/2` is what the spec invokes; calling it directly is
    # calling it the way Horde does.

    test "each start mints its own key and a stop revokes only that one", %{fake: fake} do
      identity = insert_buzz_identity()

      assert {:ok, pid1} = Manager.start_harness_link(identity.id, launch_opts(fake))
      assert active_key_count(identity.user_id) == 1
      [key1] = active_keys(identity.user_id)

      # The old node going away: terminate runs, the key is revoked.
      GenServer.stop(pid1)
      assert active_key_count(identity.user_id) == 0

      # The new node replaying the same spec: a fresh key, not the dead one.
      assert {:ok, pid2} = Manager.start_harness_link(identity.id, launch_opts(fake))
      assert [key2] = active_keys(identity.user_id)
      refute key2.id == key1.id
      GenServer.stop(pid2)
    end

    test "the launcher path is read at start, so a version bump cannot strand it", %{
      fake: fake
    } do
      identity = insert_buzz_identity()
      dir = Path.dirname(fake)
      old = Path.join(dir, "old-launch.sh")
      new = Path.join(dir, "new-launch.sh")
      real_launcher = Application.app_dir(:fountain_buzz, "priv/buzz-acp-launch.sh")

      for launcher <- [old, new] do
        File.write!(launcher, "#!/bin/sh\nexec \"#{real_launcher}\" \"$@\"\n")
        File.chmod!(launcher, 0o755)
      end

      Application.put_env(:fountain_buzz, :buzz_acp_launcher, old)
      on_exit(fn -> Application.delete_env(:fountain_buzz, :buzz_acp_launcher) end)

      assert {:ok, pid1} = Manager.start_harness_link(identity.id, launch_opts(fake))
      assert :sys.get_state(pid1).launcher == old
      GenServer.stop(pid1)

      # "The next release": the launcher lives somewhere else now.
      Application.put_env(:fountain_buzz, :buzz_acp_launcher, new)
      assert {:ok, pid2} = Manager.start_harness_link(identity.id, launch_opts(fake))
      assert :sys.get_state(pid2).launcher == new
      GenServer.stop(pid2)
    end

    test "an identity that was disabled or deleted is dropped, not restarted forever", %{
      fake: fake
    } do
      identity = insert_buzz_identity()
      {:ok, _} = FountainBuzz.update_identity(identity, %{enabled: false}, actor: "system:test")
      assert :ignore = Manager.start_harness_link(identity.id, launch_opts(fake))
      assert active_key_count(identity.user_id) == 0

      assert :ignore = Manager.start_harness_link(Ecto.UUID.generate(), launch_opts(fake))
    end
  end
end
