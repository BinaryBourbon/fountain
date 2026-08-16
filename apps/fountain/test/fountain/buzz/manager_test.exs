defmodule Fountain.Buzz.ManagerTest do
  # async: false — starts real harness processes under the global Horde
  # supervisor, and DataCase gives shared-mode DB so their terminate-time key
  # revocation reaches this connection.
  use Fountain.DataCase, async: false

  import Ecto.Query

  alias Fountain.Accounts.ApiKey
  alias Fountain.Buzz.Manager
  alias Fountain.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "buzz-mgr-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    fake = Path.join(dir, "buzz-acp")
    File.write!(fake, "#!/bin/sh\nsleep 30\n")
    File.chmod!(fake, 0o755)

    on_exit(fn ->
      # Tear down every harness this test left running (no prod harnesses exist
      # under this supervisor in the test node) before the tmp dir goes away.
      for {_, pid, _, _} <- Horde.DynamicSupervisor.which_children(Fountain.BuzzSupervisor),
          is_pid(pid) do
        Horde.DynamicSupervisor.terminate_child(Fountain.BuzzSupervisor, pid)
      end

      File.rm_rf(dir)
    end)

    %{fake: fake}
  end

  defp launch_opts(fake), do: [buzz_acp_path: fake, base_url: "https://fountain.test"]

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

    refute Manager.running?(identity.id)
    # terminate_child is synchronous, so the harness's on_stop (key revoke) has run.
    assert active_key_count(identity.user_id) == 0
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
end
