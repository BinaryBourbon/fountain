Code.require_file("mix-diagnostics.exs", __DIR__)
ExUnit.start()
Application.ensure_all_started(:mix)

defmodule Fountain.CI.MixDiagnosticsTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO
  alias Fountain.CI.MixDiagnostics

  test "reports a real lock holder and waiter without exposing their process dictionaries" do
    parent = self()
    key = "fountain-ci-diagnostics-#{System.pid()}-#{System.unique_integer([:positive])}"

    holder =
      spawn(fn ->
        Process.put(:credentials, "do-not-log-this-secret")

        Mix.Sync.Lock.with_lock(key, fn ->
          send(parent, :ready)
          receive do: (:stop -> :ok)
        end)
      end)

    holder_ref = Process.monitor(holder)

    try do
      assert_receive :ready, 5_000

      waiter =
        spawn(fn ->
          Mix.Sync.Lock.with_lock(key, fn -> :ok end,
            on_taken: fn _ -> send(parent, :waiting) end
          )
        end)

      waiter_ref = Process.monitor(waiter)

      try do
        assert_receive :waiting, 5_000
        snapshot = MixDiagnostics.snapshot()
        assert snapshot =~ inspect(holder)
        assert snapshot =~ inspect(waiter)
        assert snapshot =~ "Mix.Sync.Lock"
        assert snapshot =~ "OS pid #{System.pid()}"
        assert snapshot =~ "OS process tree"
        refute snapshot =~ "do-not-log-this-secret"
      after
        send(holder, :stop)
        assert_receive {:DOWN, ^waiter_ref, :process, ^waiter, :normal}, 5_000
      end
    after
      send(holder, :stop)
      assert_receive {:DOWN, ^holder_ref, :process, ^holder, :normal}, 5_000
    end
  end

  test "periodic diagnostics stop without affecting the caller" do
    output =
      capture_io(:stderr, fn ->
        pid = MixDiagnostics.start(1)
        ref = Process.monitor(pid)

        # Wait on the actual write, not on a scheduler sleep.
        :erlang.trace(pid, true, [:send])
        assert_receive {:trace, ^pid, :send, {:io_request, _, _, _}, _}, 5_000
        send(pid, :stop)
        assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
      end)

    assert output =~ "Mix setup still running"
  end
end
