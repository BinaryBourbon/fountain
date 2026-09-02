defmodule Managoat.Runner.AdapterTest do
  @moduledoc """
  The adapter's answers when there is no daemon to ask, and when the daemon
  answers with a reply of the wrong shape. The conformance suite covers the
  happy paths; these pin the error shapes a host's provisioning code and
  reaper branch on, with the test process standing in as the connection.
  """
  use ExUnit.Case, async: true

  alias Managoat.Runner.Adapter
  alias Managoat.Runner.Host.Local
  alias Managoat.Runner.Names
  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy

  @offline "00000000-0000-4000-8000-00000000aaaa"
  @stub "00000000-0000-4000-8000-00000000bbbb"

  describe "identity" do
    test "provider, capabilities and the unsupported governance calls" do
      assert Adapter.provider() == :runner
      assert Adapter.capabilities() == MapSet.new([:suspend, :attach])
      handle = Adapter.build_handle("runner-x")
      assert %Handle{provider: :runner, name: "runner-x"} = handle
      assert {:error, :unsupported} = Adapter.public_url(handle)

      assert {:error, :not_supported} =
               Adapter.apply_network_policy(handle, %NetworkPolicy{allow: []})

      assert {:error, :not_supported} = Adapter.create_checkpoint(handle, [])
      assert {:error, :not_supported} = Adapter.restore_checkpoint(handle, "cp")
    end

    test "a name that does not carry a runner id is :invalid" do
      assert {:error, {:invalid, {:not_a_runner_sandbox_name, "sprite-1"}}} =
               Adapter.runner_id("sprite-1")

      assert {:error, {:invalid, _}} = Adapter.create("sprite-1", [])
    end
  end

  describe "with the runner offline" do
    setup do
      handle = Adapter.build_handle(Names.for_runner(@offline))
      command = command(@offline, handle.name)
      %{handle: handle, command: command}
    end

    test "every request is {:unavailable, :runner_offline}", %{handle: handle, command: command} do
      offline = {:error, {:unavailable, :runner_offline}}
      assert ^offline = Adapter.create(handle.name, [])
      assert ^offline = Adapter.get(handle)
      assert ^offline = Adapter.destroy(handle)
      assert ^offline = Adapter.suspend(handle)
      assert ^offline = Adapter.resume(handle)
      assert ^offline = Adapter.write_file(handle, "/f", "data", [])
      assert ^offline = Adapter.exec(handle, "true", [], [])
      assert ^offline = Adapter.spawn(handle, "true", [], [])
      assert ^offline = Adapter.list_sessions(handle)
      assert ^offline = Adapter.attach(handle, "s-1", [])
      assert ^offline = Adapter.close_stdin(command)
    end

    test "a stdin write on an offline runner is a write failure, and stop is total",
         %{command: command} do
      assert {:error, {:write_failed, :runner_offline}} = Adapter.write_stdin(command, "x")
      assert :ok = Adapter.stop_command(command)
    end

    test "host_path falls back to the input", %{handle: handle} do
      assert Adapter.host_path(handle, "/home/sprite/x") == "/home/sprite/x"
    end
  end

  describe "with a daemon that answers in the wrong shape" do
    setup do
      # A stub connection process: `call/3` finds it through the host and
      # sends `{:rpc, from, ref, payload, subscribe}`; it replies with the
      # next scripted result as the real connection would after decoding a
      # frame. `answer/1` queues one.
      test = self()

      stub =
        spawn_link(fn ->
          :ok = Local.register(@stub, %{})
          send(test, :registered)
          stub_loop([])
        end)

      assert_receive :registered
      Process.put(:stub, stub)
      handle = Adapter.build_handle(Names.for_runner(@stub))
      %{handle: handle, command: command(@stub, handle.name)}
    end

    test "list_all_names refuses the whole view on a malformed list" do
      answer({:ok, %{"names" => "nope"}})

      assert {:error, {:provider, :runner, {:malformed_list, %{"names" => "nope"}}}} =
               Adapter.list_all_names()

      answer({:error, {:unavailable, :runner_timeout}})
      assert {:error, {:unavailable, :runner_timeout}} = Adapter.list_all_names()

      answer({:ok, %{"names" => ["a", "b"]}})
      assert {:ok, names} = Adapter.list_all_names()
      assert MapSet.subset?(MapSet.new(["a", "b"]), names)
    end

    test "get reports an unknown status honestly", %{handle: handle} do
      answer({:ok, %{"status" => "weird"}})
      assert {:ok, %{status: :unknown}} = Adapter.get(handle)
      answer({:ok, %{"status" => "suspended"}})
      assert {:ok, %{status: :suspended}} = Adapter.get(handle)
    end

    test "destroy tolerates not_found and passes other errors on", %{handle: handle} do
      answer({:error, :not_found})
      assert :ok = Adapter.destroy(handle)
      answer({:error, {:provider, :runner, "boom"}})
      assert {:error, {:provider, :runner, "boom"}} = Adapter.destroy(handle)
    end

    test "exec, spawn, attach and list_sessions name the malformed reply", %{handle: handle} do
      answer({:ok, %{"output" => "x"}})

      assert {:error, {:provider, :runner, {:malformed_exec_reply, _}}} =
               Adapter.exec(handle, "true", [], timeout: 1_000)

      answer({:ok, %{}})

      assert {:error, {:provider, :runner, {:malformed_spawn_reply, %{}}}} =
               Adapter.spawn(handle, "true", [], [])

      answer({:ok, %{"session_id" => "other"}})

      assert {:error, {:provider, :runner, {:malformed_attach_reply, _}}} =
               Adapter.attach(handle, "s-1", [])

      answer({:ok, %{"sessions" => "nope"}})

      assert {:error, {:provider, :runner, {:malformed_sessions_reply, _}}} =
               Adapter.list_sessions(handle)

      answer({:error, :not_found})
      assert {:error, :not_found} = Adapter.list_sessions(handle)
    end

    test "exec decodes output and passes the exit code as data", %{handle: handle} do
      answer({:ok, %{"output" => Base.encode64("hi"), "code" => 7}})
      assert {:ok, "hi", 7} = Adapter.exec(handle, "true", [], env: [{"A", 1}], dir: "/d")

      answer({:ok, %{"output" => "not base64!", "code" => 0}})
      assert {:ok, "not base64!", 0} = Adapter.exec(handle, "true", [], [])
    end

    test "list_sessions maps the daemon's session rows", %{handle: handle} do
      answer(
        {:ok,
         %{
           "sessions" => [
             %{"id" => "s-1", "command" => "bash", "created_at" => "2026-09-01T00:00:00Z"},
             %{"id" => "s-2", "created_at" => "not a time", "tty" => true}
           ]
         }}
      )

      assert {:ok, [s1, s2]} = Adapter.list_sessions(handle)
      assert s1.id == "s-1" and s1.command == "bash" and s1.tty == false
      assert %DateTime{} = s1.created_at
      assert s2.id == "s-2" and s2.tty == true and s2.created_at == nil
    end

    test "stdin errors map onto the write contract", %{command: command} do
      answer({:error, :not_found})
      assert {:error, :command_exited} = Adapter.write_stdin(command, "x")
      answer({:error, :command_exited})
      assert {:error, :command_exited} = Adapter.write_stdin(command, "x")
      answer({:error, {:invalid, "bad"}})
      assert {:error, {:invalid, "bad"}} = Adapter.write_stdin(command, "x")

      answer({:error, :not_found})
      assert :ok = Adapter.close_stdin(command)
      answer({:error, :command_exited})
      assert :ok = Adapter.close_stdin(command)
      answer({:error, {:invalid, "bad"}})
      assert {:error, {:invalid, "bad"}} = Adapter.close_stdin(command)
    end
  end

  # Queue the reply to the adapter's next request.
  defp answer(result) do
    send(Process.get(:stub), {:script, result})
    :ok
  end

  defp stub_loop(script) do
    receive do
      {:script, result} ->
        stub_loop(script ++ [result])

      {:rpc, from, ref, _payload, _subscribe} ->
        [result | rest] = script
        send(from, {:runner_reply, ref, result})
        stub_loop(rest)
    end
  end

  defp command(runner_id, name) do
    %Command{
      provider: :runner,
      ref: make_ref(),
      private: %{runner_id: runner_id, name: name, session_id: "s-1"}
    }
  end
end
