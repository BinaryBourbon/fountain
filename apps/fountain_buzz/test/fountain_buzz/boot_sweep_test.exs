defmodule FountainBuzz.BootSweepTest do
  # async: false — sets application env and starts real harnesses under the
  # global Horde supervisor.
  use Fountain.DataCase, async: false
  import FountainBuzz.Factory

  alias FountainBuzz.{BootSweep, Manager}

  setup do
    dir = Fountain.TmpDir.mkdir!("buzz-sweep")
    fake = Path.join(dir, "buzz-acp")
    FountainBuzz.TestSupport.write_fake_acp!(fake)

    prev_path = Application.get_env(:fountain_buzz, :buzz_acp_path)
    prev_url = Application.get_env(:fountain_buzz, :buzz_acp_base_url)

    on_exit(fn ->
      restore(:buzz_acp_path, prev_path)
      restore(:buzz_acp_base_url, prev_url)

      FountainBuzz.TestSupport.stop_all_harnesses!()

      File.rm_rf(dir)
    end)

    %{fake: fake, dir: dir}
  end

  defp restore(key, nil), do: Application.delete_env(:fountain_buzz, key)
  defp restore(key, val), do: Application.put_env(:fountain_buzz, key, val)

  test "enabled? needs a buzz-acp that is there AND is the pinned version", %{fake: fake} do
    # A core distribution: no binary, nothing to sweep.
    Application.delete_env(:fountain_buzz, :buzz_acp_path)
    refute BootSweep.enabled?()

    # A path pointing at nothing is the same answer, not a crash.
    Application.put_env(:fountain_buzz, :buzz_acp_path, "/no/such/buzz-acp")
    refute BootSweep.enabled?()

    # The bundled distribution: present, and reporting the version this
    # extension was built against.
    Application.put_env(:fountain_buzz, :buzz_acp_path, fake)
    assert BootSweep.enabled?()
  end

  test "enabled? refuses a binary of the wrong version rather than crash-looping it", %{
    dir: dir
  } do
    # The partial upgrade #1509 asks to fail early: a new extension beside an
    # old binary. Inert and logged beats one crashing harness per identity.
    wrong = Path.join(dir, "wrong-version")

    File.write!(
      wrong,
      "#!/bin/sh\nif [ \"$1\" = \"--version\" ]; then echo 'buzz-acp 0.0.1'; exit 0; fi\nexec sleep 30\n"
    )

    File.chmod!(wrong, 0o755)

    Application.put_env(:fountain_buzz, :buzz_acp_path, wrong)

    log = ExUnit.CaptureLog.capture_log(fn -> refute BootSweep.enabled?() end)
    assert log =~ "0.0.1"
    assert log =~ FountainBuzz.Assets.pinned_version()
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
