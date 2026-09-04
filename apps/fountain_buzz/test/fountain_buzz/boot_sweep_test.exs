defmodule FountainBuzz.BootSweepTest do
  # async: false — sets application env and starts real harnesses under the
  # global Horde supervisor.
  use Fountain.DataCase, async: false
  import FountainBuzz.Factory

  alias FountainBuzz.{BootSweep, Manager}

  setup do
    dir = Fountain.TmpDir.mkdir!("buzz-sweep")
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

    %{fake: fake}
  end

  defp restore(key, nil), do: Application.delete_env(:fountain_buzz, key)
  defp restore(key, val), do: Application.put_env(:fountain_buzz, key, val)

  test "enabled? follows the :buzz_acp_path config" do
    Application.delete_env(:fountain_buzz, :buzz_acp_path)
    refute BootSweep.enabled?()

    Application.put_env(:fountain_buzz, :buzz_acp_path, "/some/path")
    assert BootSweep.enabled?()
  end

  test "run starts a harness for each enabled identity and skips disabled ones", %{fake: fake} do
    Application.put_env(:fountain_buzz, :buzz_acp_path, fake)
    Application.put_env(:fountain_buzz, :buzz_acp_base_url, "https://fountain.test")

    a = insert_buzz_identity(%{"enabled" => true})
    b = insert_buzz_identity(%{"enabled" => true})
    disabled = insert_buzz_identity(%{"enabled" => false})

    started = BootSweep.run()
    assert started >= 2

    assert Manager.running?(a.id)
    assert Manager.running?(b.id)
    refute Manager.running?(disabled.id)
  end

  test "run is idempotent — a second sweep does not double-start", %{fake: fake} do
    Application.put_env(:fountain_buzz, :buzz_acp_path, fake)
    Application.put_env(:fountain_buzz, :buzz_acp_base_url, "https://fountain.test")

    identity = insert_buzz_identity(%{"enabled" => true})

    BootSweep.run()
    pid = Manager.whereis(identity.id)
    assert is_pid(pid)

    BootSweep.run()
    assert Manager.whereis(identity.id) == pid
  end
end
