ExUnit.start()
Application.ensure_all_started(:mix)

source = Path.join([:code.lib_dir(:mix), "lib/mix/sync/lock.ex"]) |> File.read!()
patch_dir = :code.which(Mix.Sync.Lock) |> List.to_string() |> Path.dirname() |> Path.dirname()
patched_source = Path.join(patch_dir, "lib/mix/lib/mix/sync/lock.ex") |> File.read!()

# Control only the OS port allocator: the first listen chooses a real free
# port, and the second listen requests that same port after the first closes.
# Both versions still use their actual TCP probes, hardlinks and lock code.
for {module, text} <- [
      {Fountain.CI.OldMixLock, source},
      {Fountain.CI.FixedMixLock, patched_source}
    ] do
  for needle <- [
        "defmodule Mix.Sync.Lock do",
        ":gen_tcp.listen(0, @listen_opts)",
        "{:ok, port} ->\n          {:ok, socket, port}"
      ] do
    unless length(String.split(text, needle)) == 2,
      do: raise("allocator instrumentation no longer matches the audited source")
  end

  text =
    text
    |> String.replace("defmodule Mix.Sync.Lock do", "defmodule #{inspect(module)} do")
    |> String.replace(
      ":gen_tcp.listen(0, @listen_opts)",
      ":gen_tcp.listen(Process.get(:test_listener_port, 0), @listen_opts)"
    )
    |> String.replace(
      "{:ok, port} ->\n          {:ok, socket, port}",
      "{:ok, port} ->\n          Process.put(:test_listener_port, port)\n          {:ok, socket, port}"
    )

  Code.compile_string(text)
end

defmodule Fountain.CI.MixLockBackportTest do
  use ExUnit.Case, async: false

  alias Fountain.CI.{FixedMixLock, OldMixLock}

  defp key do
    "fountain-backport-test-#{System.pid()}-#{System.unique_integer([:positive])}"
  end

  defp cleanup(key, version) do
    hash = key |> :erlang.md5() |> Base.url_encode64(padding: false)
    root = "mix_lock_#{version}user#{Mix.Utils.detect_user_id!()}"
    File.rm_rf!(Path.join([System.tmp_dir!(), root, hash]))
  end

  defp stop(pid, ref) do
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
  end

  test "pinned Mix deadlocks on its own reused port, the exact backport acquires" do
    for {module, version, expected} <- [
          {OldMixLock, "", :self_wait},
          {FixedMixLock, "v2_", :acquired}
        ] do
      key = key()
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          module.with_lock(key, fn -> :ok end)
          send(parent, {:reusing_port, Process.get(:test_listener_port)})

          module.with_lock(key, fn -> send(parent, :acquired) end,
            on_taken: fn owner -> send(parent, {:self_wait, owner}) end
          )
        end)

      try do
        assert_receive {:reusing_port, port}, 5_000
        assert is_integer(port) and port > 0

        case expected do
          :self_wait ->
            os_pid = System.pid()
            assert_receive {:self_wait, ^os_pid}, 5_000
            refute_received :acquired

          :acquired ->
            assert_receive :acquired, 5_000
            refute_received {:self_wait, _}
        end
      after
        stop(pid, ref)
        cleanup(key, version)
      end
    end
  end

  test "backport takes over a crashed owner's port when the OS reassigns it" do
    key = key()
    parent = self()

    {owner, owner_ref} =
      spawn_monitor(fn ->
        FixedMixLock.with_lock(key, fn ->
          send(parent, {:port, Process.get(:test_listener_port)})
          Process.sleep(:infinity)
        end)
      end)

    try do
      assert_receive {:port, port}, 5_000
      stop(owner, owner_ref)

      {pid, ref} =
        spawn_monitor(fn ->
          Process.put(:test_listener_port, port)
          FixedMixLock.with_lock(key, fn -> send(parent, :acquired) end)
        end)

      try do
        assert_receive :acquired, 5_000
      after
        stop(pid, ref)
      end
    after
      if Process.alive?(owner), do: stop(owner, owner_ref)
      cleanup(key, "v2_")
    end
  end

  test "ordinary patched child VMs inherit the fix and preserve mutual exclusion" do
    key = key()
    beam = :code.which(Mix.Sync.Lock) |> List.to_string()

    owner =
      child("""
      Application.ensure_all_started(:mix)
      IO.puts("module:" <> to_string(:code.which(Mix.Sync.Lock)))
      Mix.Sync.Lock.with_lock(#{inspect(key)}, fn ->
        IO.puts("held:" <> System.pid())
        IO.gets("")
      end)
      """)

    try do
      assert_receive {^owner, {:data, {:eol, "module:" <> ^beam}}}, 5_000
      assert_receive {^owner, {:data, {:eol, "held:" <> owner_pid}}}, 5_000

      waiter =
        child("""
        Application.ensure_all_started(:mix)
        IO.puts("module:" <> to_string(:code.which(Mix.Sync.Lock)))
        Mix.Sync.Lock.with_lock(#{inspect(key)}, fn -> IO.puts("acquired") end,
          on_taken: fn owner -> IO.puts("waiting:" <> owner) end)
        """)

      try do
        assert_receive {^waiter, {:data, {:eol, "module:" <> ^beam}}}, 5_000
        assert_receive {^waiter, {:data, {:eol, "waiting:" <> ^owner_pid}}}, 5_000
        refute_received {^waiter, {:data, {:eol, "acquired"}}}
        Port.command(owner, "release\n")
        assert_receive {^waiter, {:data, {:eol, "acquired"}}}, 5_000
        assert_receive {^owner, {:exit_status, 0}}, 5_000
        assert_receive {^waiter, {:exit_status, 0}}, 5_000
      after
        close(owner)
        close(waiter)
      end
    after
      close(owner)
      cleanup(key, "v2_")
    end
  end

  test "inherited preload flags also allow embedded release boot" do
    executable = System.find_executable("erl") |> String.to_charlist()

    child =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        {:line, 4096},
        args: [
          "-mode",
          "embedded",
          "-noshell",
          "-eval",
          "io:format(\"embedded started~n\"), halt()."
        ]
      ])

    try do
      assert_receive {^child, {:data, {:eol, "embedded started"}}}, 5_000
      assert_receive {^child, {:exit_status, 0}}, 5_000
    after
      close(child)
    end
  end

  defp child(code) do
    executable = System.find_executable("elixir") |> String.to_charlist()

    Port.open({:spawn_executable, executable}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      {:line, 4096},
      args: ["-e", code]
    ])
  end

  defp close(port) do
    if Port.info(port) != nil, do: Port.close(port)
  end
end
