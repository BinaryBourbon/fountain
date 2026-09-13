defmodule Fountain.CI.MixDiagnostics do
  @moduledoc false

  # Loaded before Mix, so a compiler lock stall cannot prevent diagnostics.
  # No application env, process messages, dictionary values or argv are logged.
  def start(interval_ms \\ 60_000) do
    spawn(fn -> loop(interval_ms) end)
  end

  defp loop(interval_ms) do
    receive do
      :stop -> :ok
    after
      interval_ms ->
        IO.puts(:stderr, snapshot())
        loop(interval_ms)
    end
  end

  def snapshot do
    processes =
      for pid <- Process.list(),
          info = Process.info(pid, [:current_stacktrace, :dictionary, :registered_name, :status]),
          info != nil,
          relevant?(info) do
        locks =
          for {{Mix.Sync.Lock, path}, true} <- info[:dictionary], do: path

        # Frame arguments can contain credentials. Keep only function arities.
        stack = Enum.map(info[:current_stacktrace], &frame/1)
        inspect({pid, info[:registered_name], info[:status], locks, stack}, limit: :infinity)
      end

    "Mix setup still running: OS pid #{System.pid()}, cwd #{File.cwd!()}\n" <>
      Enum.join(processes, "\n") <>
      "\nOS process tree (pid, ppid, status, executable):\n" <>
      process_tree()
  end

  defp relevant?(info) do
    Enum.any?(info[:dictionary], &match?({{Mix.Sync.Lock, _}, true}, &1)) or
      Enum.any?(info[:current_stacktrace], fn {module, _, _, _} ->
        String.starts_with?(Atom.to_string(module), "Elixir.Mix.")
      end)
  end

  defp frame({module, function, args, location}) when is_list(args),
    do: {module, function, length(args), location}

  defp frame(frame), do: frame

  defp process_tree do
    case System.find_executable("ps") do
      nil ->
        "ps unavailable"

      executable ->
        {output, _status} = System.cmd(executable, ["-axo", "pid=,ppid=,stat=,comm="])
        output
    end
  end
end

if System.get_env("MIX_DIAGNOSTICS") == "1", do: Fountain.CI.MixDiagnostics.start()
