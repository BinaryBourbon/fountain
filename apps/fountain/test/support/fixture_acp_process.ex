defmodule Fountain.FixtureAcpProcess do
  @moduledoc """
  Run a fixture ACP agent as a real OS process, framed as a sandbox command.

  `Managoat.Sandbox.Fake` speaks a scripted instruction vocabulary rather than
  running programs, so it cannot host an agent that has to read what the
  client wrote and answer it. This does the smallest thing that can: a port to
  `test/fixtures/acp_agent.exs`, and a relay that turns the port's frames into
  the `{:stdout | :exit, %{ref: ref}, _}` messages `Managoat.Sandbox` promises
  a command's owner.

  It is the test sandbox provider for one purpose (#1634): proving that a
  `ConversationServer` drives a whole turn against a program it did not write,
  over the same stdio the four LLM runtimes use. Everything else about the
  sandbox stays stubbed by `Fountain.ConversationServerCase`.
  """

  @fixture "acp_agent.exs"

  @doc """
  Stub `Managoat.Sandbox.Sprites`'s streaming calls onto a real fixture agent.

  Returns the ref every frame from it will carry. The relay is started here
  and opens its port when the spawn arrives, so it can send to that spawn's
  `:owner` (the conversation server) without anybody knowing the pid first.
  """
  @spec stub_spawn() :: reference()
  def stub_spawn do
    ref = make_ref()
    relay = spawn(fn -> await_start(ref) end)

    # The conversation server does not stop its command on terminate, so
    # without this the fixture's own OS process would outlive the test.
    ExUnit.Callbacks.on_exit(fn -> send(relay, :stop) end)

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _handle, _cmd, _args, opts ->
      send(relay, {:start, Keyword.fetch!(opts, :owner)})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _command, data ->
      send(relay, {:write, IO.iodata_to_binary(data)})
      :ok
    end)

    # A port has no half-close, and this turn ends on the stop reason rather
    # than on EOF, so the close is a no-op and `stop_command/1` is what ends
    # the process.
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _command -> :ok end)

    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _command ->
      send(relay, :stop)
      :ok
    end)

    ref
  end

  @doc "Absolute path of the checked-in fixture agent."
  @spec fixture_path() :: String.t()
  def fixture_path, do: Path.expand(Path.join([__DIR__, "..", "fixtures", @fixture]))

  # Unlinked, and it waits rather than opening the port eagerly: writes that
  # somehow arrive first stay in the mailbox until the loop reaches them.
  defp await_start(ref) do
    receive do
      {:start, owner} ->
        port =
          Port.open({:spawn_executable, elixir_executable()}, [
            :binary,
            :exit_status,
            :use_stdio,
            {:line, 1_000_000},
            {:args, [fixture_path()]}
          ])

        relay(port, owner, ref)

      :stop ->
        :ok
    end
  end

  defp elixir_executable do
    System.find_executable("elixir") ||
      raise "elixir is not on PATH; the fixture ACP agent cannot run"
  end

  defp relay(port, owner, ref) do
    receive do
      {:write, data} ->
        Port.command(port, data)
        relay(port, owner, ref)

      :stop ->
        safe_close(port)
        send(owner, {:exit, %{ref: ref}, 0})

      {^port, {:data, {:eol, line}}} ->
        send(owner, {:stdout, %{ref: ref}, line <> "\n"})
        relay(port, owner, ref)

      {^port, {:data, {:noeol, chunk}}} ->
        send(owner, {:stdout, %{ref: ref}, chunk})
        relay(port, owner, ref)

      {^port, {:exit_status, code}} ->
        send(owner, {:exit, %{ref: ref}, code})
    end
  end

  defp safe_close(port) do
    Port.close(port)
  catch
    _, _ -> :ok
  end
end
