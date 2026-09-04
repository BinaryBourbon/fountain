defmodule FountainBuzz.Workers.HarnessSweepTest do
  @moduledoc """
  The balance applied to the one cost no sandbox meter sees (#1017).

  `async: false`: sets application env and starts real harnesses under the
  global Horde supervisor, the same reasons `BootSweepTest` gives.
  """

  use Fountain.DataCase, async: false
  import FountainBuzz.Factory

  alias FountainBuzz.{BootSweep, Manager}
  alias Fountain.Credits
  alias FountainBuzz.Workers.HarnessSweep, as: BuzzHarnessSweep

  setup do
    dir = Fountain.TmpDir.mkdir!("buzz-harness-sweep")
    fake = Path.join(dir, "buzz-acp")
    File.write!(fake, "#!/bin/sh\nexec sleep 30\n")
    File.chmod!(fake, 0o755)

    prev_path = Application.get_env(:fountain_buzz, :buzz_acp_path)
    prev_url = Application.get_env(:fountain_buzz, :buzz_acp_base_url)

    on_exit(fn ->
      restore(:buzz_acp_path, prev_path)
      restore(:buzz_acp_base_url, prev_url)
      FountainBuzz.TestSupport.stop_all_harnesses!()
      File.rm_rf(dir)
    end)

    Application.put_env(:fountain_buzz, :buzz_acp_path, fake)
    Application.put_env(:fountain_buzz, :buzz_acp_base_url, "https://fountain.test")

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain_buzz, key)
  defp restore(key, val), do: Application.put_env(:fountain_buzz, key, val)

  defp drain(user_id) do
    case Credits.balance(user_id) do
      0 -> :ok
      cents -> {:ok, _} = Credits.debit(user_id, cents, "burn_turn", idempotency_key: "drain")
    end
  end

  test "stops the harness of a tenant who cannot spend, and keeps the row enabled" do
    identity = insert_buzz_identity(%{"enabled" => true})
    assert {:ok, _} = Manager.start_harness(identity)
    assert Manager.running?(identity.id)

    drain(identity.user_id)

    assert %{stopped: 1} = BuzzHarnessSweep.run()
    refute Manager.running?(identity.id)

    # Park, do not destroy (ADR 0017's shape): the account is out of credit,
    # not gone, so a top-up brings the same agent back rather than asking the
    # provider to deploy it again. `enabled` is the tenant's own lever and the
    # sweep never touches it.
    assert FountainBuzz._unsafe_get_identity(identity.id).enabled
  end

  test "starts a harness again once the tenant can spend" do
    identity = insert_buzz_identity(%{"enabled" => true})
    drain(identity.user_id)

    assert %{started: 0} = BuzzHarnessSweep.run()
    refute Manager.running?(identity.id)

    {:ok, _} = Credits.grant(identity.user_id, 500, "grant_admin", idempotency_key: "top-up")

    assert %{started: 1} = BuzzHarnessSweep.run()
    assert Manager.running?(identity.id)
  end

  test "leaves a funded tenant's running harness alone" do
    identity = insert_buzz_identity(%{"enabled" => true})
    assert {:ok, pid} = Manager.start_harness(identity)

    assert %{stopped: 0, started: 0} = BuzzHarnessSweep.run()
    assert Manager.whereis(identity.id) == pid
  end

  test "ignores a disabled identity whatever the balance" do
    identity = insert_buzz_identity(%{"enabled" => false})
    drain(identity.user_id)

    assert %{stopped: 0, started: 0} = BuzzHarnessSweep.run()
    refute Manager.running?(identity.id)
  end

  test "is inert with no buzz-acp binary configured" do
    Application.delete_env(:fountain_buzz, :buzz_acp_path)
    refute BootSweep.enabled?()

    identity = insert_buzz_identity(%{"enabled" => true})
    drain(identity.user_id)

    # Nothing to stop and nothing to start: the sweep must not query, log or
    # act on an instance that runs no harnesses at all.
    assert %{stopped: 0, started: 0} = BuzzHarnessSweep.run()
  end

  test "asks the gate once per tenant, not once per identity" do
    user = insert_verified_user()
    agent = insert_agent(%{"user_id" => user.id})

    for _ <- 1..3 do
      insert_buzz_identity(%{"user_id" => user.id, "agent_id" => agent.id, "enabled" => true})
    end

    drain(user.id)

    assert %{stopped: 0, started: 0} = BuzzHarnessSweep.run()
  end

  test "the boot sweep skips a tenant who cannot spend" do
    funded = insert_buzz_identity(%{"enabled" => true})
    broke = insert_buzz_identity(%{"enabled" => true})
    drain(broke.user_id)

    BootSweep.run()

    # Without this the boot sweep would undo the harness sweep on every
    # deploy: stopped at 15 past the hour, back up at the next rollout.
    assert Manager.running?(funded.id)
    refute Manager.running?(broke.id)
  end
end
