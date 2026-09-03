defmodule Fountain.Buzz.BootSweepTest do
  # async: false — sets application env and starts real harnesses under the
  # global Horde supervisor.
  use Fountain.DataCase, async: false

  alias Fountain.Buzz.{BootSweep, Manager}

  setup do
    dir = Fountain.TmpDir.mkdir!("buzz-sweep")
    fake = Path.join(dir, "buzz-acp")
    File.write!(fake, "#!/bin/sh\nsleep 30\n")
    File.chmod!(fake, 0o755)

    prev_path = Application.get_env(:fountain, :buzz_acp_path)
    prev_url = Application.get_env(:fountain, :buzz_acp_base_url)

    on_exit(fn ->
      restore(:buzz_acp_path, prev_path)
      restore(:buzz_acp_base_url, prev_url)

      for {_, pid, _, _} <- Horde.DynamicSupervisor.which_children(Fountain.BuzzSupervisor),
          is_pid(pid) do
        Horde.DynamicSupervisor.terminate_child(Fountain.BuzzSupervisor, pid)
      end

      File.rm_rf(dir)
    end)

    %{fake: fake}
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, val), do: Application.put_env(:fountain, key, val)

  test "enabled? follows the :buzz_acp_path config" do
    Application.delete_env(:fountain, :buzz_acp_path)
    refute BootSweep.enabled?()

    Application.put_env(:fountain, :buzz_acp_path, "/some/path")
    assert BootSweep.enabled?()
  end

  test "run starts a harness for each enabled identity and skips disabled ones", %{fake: fake} do
    Application.put_env(:fountain, :buzz_acp_path, fake)
    Application.put_env(:fountain, :buzz_acp_base_url, "https://fountain.test")

    a = insert_buzz_identity(%{"enabled" => true})
    b = insert_buzz_identity(%{"enabled" => true})
    disabled = insert_buzz_identity(%{"enabled" => false})

    started = BootSweep.run()
    assert started >= 2

    assert Manager.running?(a.id)
    assert Manager.running?(b.id)
    refute Manager.running?(disabled.id)
  end

  test "run is idempotent — a second sweep does not double-start" do
    fake = Fountain.TmpDir.path("buzz-acp")
    File.write!(fake, "#!/bin/sh\nsleep 30\n")
    File.chmod!(fake, 0o755)
    on_exit(fn -> File.rm(fake) end)

    Application.put_env(:fountain, :buzz_acp_path, fake)
    Application.put_env(:fountain, :buzz_acp_base_url, "https://fountain.test")

    identity = insert_buzz_identity(%{"enabled" => true})

    BootSweep.run()
    pid = Manager.whereis(identity.id)
    assert is_pid(pid)

    BootSweep.run()
    assert Manager.whereis(identity.id) == pid
  end
end
