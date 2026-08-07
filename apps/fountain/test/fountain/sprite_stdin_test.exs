defmodule Fountain.SpriteStdinTest do
  @moduledoc """
  These drive the real `Sprites.write/2` — no stubbing of the thing under test.
  The command process is a plain process standing in for `Sprites.Command`,
  which is enough because the only behaviour that matters here is how it dies.
  """

  use ExUnit.Case, async: true

  alias Fountain.SpriteStdin

  defp command(pid), do: %Sprites.Command{ref: make_ref(), pid: pid, tty_mode: false}

  test "a live command process still gets the data" do
    test = self()

    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:write_stdin, data}} ->
            send(test, {:wrote, data})
            GenServer.reply(from, :ok)
        end
      end)

    assert SpriteStdin.write(command(pid), "hello") == :ok
    assert_receive {:wrote, "hello"}
  end

  test "a command that stops :normal mid-write is an error, not an exit (#603)" do
    # Sprites.Command stops :normal the instant the runtime's exit frame
    # arrives. Before #603 the GenServer.call landing after that exited the
    # caller — which, in kick_turn, was the ConversationServer mid-turn.
    pid = spawn(fn -> receive(do: (_ -> exit(:normal))) end)

    assert SpriteStdin.write(command(pid), "prompt") == {:error, :command_exited}
    assert Process.alive?(self())
  end

  test "a command process that is already gone is an error, not an exit" do
    pid = spawn(fn -> :ok end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}

    assert SpriteStdin.write(command(pid), "prompt") == {:error, :command_exited}
  end

  test "an abnormal exit is reported rather than propagated" do
    pid = spawn(fn -> receive(do: (_ -> exit(:boom))) end)

    assert SpriteStdin.write(command(pid), "prompt") == {:error, {:write_failed, :boom}}
  end

  test "the library's own {:error, _} passes through untouched" do
    # The still-alive-but-disconnected clause the library already has.
    pid =
      spawn(fn ->
        receive do
          {:"$gen_call", from, {:write_stdin, _}} ->
            GenServer.reply(from, {:error, :not_connected})
        end
      end)

    assert SpriteStdin.write(command(pid), "prompt") == {:error, :not_connected}
  end
end
