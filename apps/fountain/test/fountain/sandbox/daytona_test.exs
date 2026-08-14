defmodule Fountain.Sandbox.DaytonaTest do
  # Full-stack against a Req.Test plug: adapter -> Api/Toolbox -> stubbed
  # HTTP. The websocket log stream is unit-tested at the demux level (see
  # LogStreamTest); everything REST runs here. Mutates global app env, so
  # not async.
  use ExUnit.Case, async: false
  use Mimic

  alias Fountain.Sandbox.Command
  alias Fountain.Sandbox.Daytona, as: Adapter
  alias Fountain.Sandbox.NetworkPolicy

  @name "fountain-abc12345-deadbeef"
  @toolbox "https://proxy.daytona.test/toolbox/sbx1"

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  setup do
    previous = %{
      key: Application.get_env(:fountain, :daytona_api_key),
      opts: Application.get_env(:fountain, :daytona_req_options)
    }

    Application.put_env(:fountain, :daytona_api_key, "dtn_test_key")
    Application.put_env(:fountain, :daytona_req_options, plug: {Req.Test, __MODULE__})

    on_exit(fn ->
      restore(:daytona_api_key, previous.key)
      restore(:daytona_req_options, previous.opts)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp handle, do: Adapter.build_handle(@name)

  defp sandbox_body(state) do
    %{"name" => @name, "state" => state, "toolboxProxyUrl" => @toolbox}
  end

  describe "create/2" do
    test "creates a name-addressed sandbox with fountain labels and no TTL" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:created, Jason.decode!(raw)})
            Req.Test.json(conn, sandbox_body("started"))
        end
      end)

      assert {:ok, %{provider: :daytona, name: @name}} = Adapter.create(@name, [])

      assert_received {:created, body}
      assert body["name"] == @name
      assert body["labels"] == %{"fountain" => "1"}
      assert body["ttlMinutes"] == 0
      assert body["autoStopInterval"] == 0
      assert body["autoArchiveInterval"] > 0
    end

    test "a conflicting create adopts when the follow-up get succeeds" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox"} ->
            conn |> Plug.Conn.put_status(409) |> Req.Test.json(%{"error" => "exists"})

          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("started"))
        end
      end)

      assert {:ok, %{name: @name}} = Adapter.create(@name, [])
    end
  end

  describe "get/1, suspend/1, resume/1, destroy/1" do
    test "404 is definitively not found" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end)

      assert {:error, :not_found} = Adapter.get(handle())
    end

    test "stopped and archived normalize to :suspended" do
      for state <- ["stopped", "archived"] do
        Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, sandbox_body(state)) end)
        assert {:ok, %{status: :suspended}} = Adapter.get(handle())
      end
    end

    test "suspend stops a started sandbox and no-ops on a stopped one" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("started"))

          {"POST", "/api/sandbox/" <> _rest} ->
            send(test, {:lifecycle, conn.request_path})
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.suspend(handle())
      assert_received {:lifecycle, "/api/sandbox/" <> rest}
      assert rest == "#{@name}/stop"

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, sandbox_body("stopped")) end)
      assert :ok = Adapter.suspend(handle())
    end

    test "resume starts a stopped sandbox" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("stopped"))

          {"POST", "/api/sandbox/" <> _} ->
            send(test, :started)
            Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, _handle} = Adapter.resume(handle())
      assert_received :started
    end

    test "destroy tolerates 404" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end)

      assert :ok = Adapter.destroy(handle())
    end
  end

  describe "list_all_names/0" do
    test "follows cursor pagination over fountain-labeled sandboxes" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["cursor"] do
          nil ->
            Req.Test.json(conn, %{"items" => [%{"name" => "a"}], "nextCursor" => "c2"})

          "c2" ->
            Req.Test.json(conn, %{"items" => [%{"name" => "b"}]})
        end
      end)

      assert {:ok, names} = Adapter.list_all_names()
      assert names == MapSet.new(["a", "b"])
    end
  end

  describe "exec/4" do
    test "runs one-shot through the toolbox with cwd and env in place" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("started"))

          {"POST", "/toolbox/sbx1/process/execute"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:exec, Jason.decode!(raw)})
            Req.Test.json(conn, %{"result" => "hi", "exitCode" => 3})
        end
      end)

      assert {:ok, "hi", 3} =
               Adapter.exec(handle(), "bash", ["-lc", "x"],
                 env: [{"A", "1"}],
                 dir: "/home/sprite",
                 timeout: 30_000
               )

      assert_received {:exec, body}
      assert body["cwd"] == "/home/sprite"
      assert body["timeout"] == 30
      assert body["command"] =~ "'bash' '-lc' 'x'"
    end

    test "a stopped sandbox is started before the exec reaches the toolbox" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("stopped"))

          {"POST", "/api/sandbox/" <> _} ->
            send(test, :started)
            Req.Test.json(conn, %{})

          {"POST", "/toolbox/sbx1/process/execute"} ->
            Req.Test.json(conn, %{"result" => "", "exitCode" => 0})
        end
      end)

      assert {:ok, "", 0} = Adapter.exec(handle(), "true", [], [])
      assert_received :started
    end
  end

  describe "spawn/4, attach/3 and list_sessions/1" do
    setup do
      # The websocket replayer is unit-tested at the demux level; here it is
      # stubbed so the session/exec plumbing can be asserted over REST.
      Mimic.stub(Fountain.Sandbox.Daytona.LogStream, :start, fn opts ->
        send(opts[:owner], {:log_stream_started, opts[:session_id], opts[:command_id]})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      :ok
    end

    test "spawn creates a tagged session, execs async, and wires the stream" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("started"))

          {"POST", "/toolbox/sbx1/process/session"} ->
            Req.Test.json(conn, %{})

          {"POST", "/toolbox/sbx1/process/session/" <> rest} ->
            assert String.ends_with?(rest, "/exec")
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:exec_async, Jason.decode!(raw)})
            Req.Test.json(conn, %{"cmdId" => "cmd-1"})
        end
      end)

      assert {:ok, %Command{provider: :daytona} = command} =
               Adapter.spawn(handle(), "claude-agent-acp", [],
                 owner: self(),
                 stdin: true,
                 detachable: true
               )

      assert command.private.command_id == "cmd-1"
      assert_received {:exec_async, %{"runAsync" => true, "suppressInputEcho" => true}}
      assert_received {:log_stream_started, session_id, "cmd-1"}
      assert String.starts_with?(session_id, "fountain-")
    end

    test "list_sessions filters to fountain sessions; attach re-streams the newest command" do
      sessions = [
        %{"sessionId" => "someone-else", "commands" => []},
        %{
          "sessionId" => "fountain-42",
          "commands" => [%{"id" => "cmd-9", "command" => "claude-agent-acp"}]
        }
      ]

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("started"))

          {"GET", "/toolbox/sbx1/process/session"} ->
            Req.Test.json(conn, sessions)
        end
      end)

      assert {:ok, [%{id: "fountain-42", command: "claude-agent-acp"}]} =
               Adapter.list_sessions(handle())

      assert {:ok, %Command{} = command} = Adapter.attach(handle(), "fountain-42", owner: self())
      assert command.private.command_id == "cmd-9"
      assert_received {:log_stream_started, "fountain-42", "cmd-9"}
    end

    test "attaching to an unknown session is definitively not found" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/api/sandbox/" <> @name} ->
            Req.Test.json(conn, sandbox_body("started"))

          {"GET", "/toolbox/sbx1/process/session"} ->
            Req.Test.json(conn, [])
        end
      end)

      assert {:error, :not_found} = Adapter.attach(handle(), "fountain-77", owner: self())
    end

    test "stop_command is total" do
      pid = spawn(fn -> Process.sleep(:infinity) end)
      command = %Command{provider: :daytona, ref: make_ref(), private: %{pid: pid}}
      assert :ok = Adapter.stop_command(command)
      assert :ok = Adapter.stop_command(command)
    end
  end

  describe "stdin" do
    test "input to a finished command is :command_exited, not a crash" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "completed"})
      end)

      command = %Command{
        provider: :daytona,
        ref: make_ref(),
        private: %{pid: self(), toolbox_url: @toolbox, session_id: "fountain-1", command_id: "c1"}
      }

      assert {:error, :command_exited} = Adapter.write_stdin(command, "late\n")
    end

    test "close_stdin is a documented no-op" do
      command = %Command{provider: :daytona, ref: make_ref(), private: %{pid: self()}}
      assert :ok = Adapter.close_stdin(command)
    end
  end

  describe "network policy" do
    test "allow: [] sends block-all with an empty allowlist — never a no-op" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/api/sandbox/" <> _rest} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:network, Jason.decode!(raw)})
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []})
      assert_received {:network, %{"networkBlockAll" => true, "domainAllowList" => []}}
    end
  end

  describe "capabilities" do
    test "suspend/network/attach advertised; checkpoints refused" do
      caps = Adapter.capabilities()
      assert MapSet.member?(caps, :suspend)
      assert MapSet.member?(caps, :network_policy)
      assert MapSet.member?(caps, :attach)
      refute MapSet.member?(caps, :checkpoint)

      assert {:error, :not_supported} = Adapter.create_checkpoint(handle(), [])
      assert {:error, :not_supported} = Adapter.restore_checkpoint(handle(), "cp")
    end
  end
end
