defmodule Fountain.Sandbox.E2BTest do
  # Full-stack against a Req.Test plug: adapter -> Api/Envd -> stubbed HTTP,
  # including the Connect streaming path through the CommandServer. Mutates
  # global app env and uses shared Req.Test ownership (the CommandServer is
  # its own process), so not async.
  use ExUnit.Case, async: false

  alias Fountain.Sandbox.Command
  alias Fountain.Sandbox.E2B, as: Adapter
  alias Fountain.Sandbox.E2B.Envd
  alias Fountain.Sandbox.NetworkPolicy

  @name "fountain-abc12345-deadbeef"

  setup :set_req_test_to_shared

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  setup do
    previous = %{
      key: Application.get_env(:fountain, :e2b_api_key),
      opts: Application.get_env(:fountain, :e2b_req_options)
    }

    Application.put_env(:fountain, :e2b_api_key, "e2b_test_key")
    Application.put_env(:fountain, :e2b_req_options, plug: {Req.Test, __MODULE__})
    # Req's plug adapter runs Plug.Parsers, which chokes on the binary
    # Connect envelope behind any +json content type.
    Application.put_env(:fountain, :e2b_stream_content_type, "application/octet-stream")

    on_exit(fn ->
      restore(:e2b_api_key, previous.key)
      restore(:e2b_req_options, previous.opts)
      Application.delete_env(:fountain, :e2b_stream_content_type)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp handle, do: Adapter.build_handle(@name)

  defp listed(state, id \\ "sbx1") do
    %{"sandboxID" => id, "state" => state, "metadata" => %{"fountain_name" => @name}}
  end

  defp end_stream_frame(map \\ %{}) do
    json = Jason.encode!(map)
    <<2, byte_size(json)::32-big, json::binary>>
  end

  defp stream_body(frames) do
    Enum.map_join(frames, "", &Envd.encode_frame/1) <> end_stream_frame()
  end

  describe "create/2" do
    test "creates when the name is unclaimed" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [])
          {"POST", "/sandboxes"} -> Req.Test.json(conn, %{"sandboxID" => "sbx-new"})
        end
      end)

      assert {:ok, %{provider: :e2b, name: @name, private: "sbx-new"}} =
               Adapter.create(@name, [])
    end

    test "adopts an existing sandbox with the same fountain name" do
      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running", "sbx-old")])
        end
      end)

      assert {:ok, %{private: "sbx-old"}} = Adapter.create(@name, [])
    end
  end

  describe "get/1, suspend/1, resume/1, destroy/1" do
    test "an unclaimed name is definitively not found" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, []) end)
      assert {:error, :not_found} = Adapter.get(handle())
    end

    test "paused normalizes to :suspended" do
      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [listed("paused")]) end)
      assert {:ok, %{status: :suspended}} = Adapter.get(handle())
    end

    test "suspend pauses a running sandbox and no-ops on a paused one" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/sandboxes/sbx1/pause"} ->
            send(test, :paused)
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.suspend(handle())
      assert_received :paused

      Req.Test.stub(__MODULE__, fn conn -> Req.Test.json(conn, [listed("paused")]) end)
      assert :ok = Adapter.suspend(handle())
    end

    test "resume connects a paused sandbox" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("paused")])

          {"POST", "/sandboxes/sbx1/connect"} ->
            send(test, :connected)
            Req.Test.json(conn, %{})
        end
      end)

      assert {:ok, %{private: "sbx1"}} = Adapter.resume(handle())
      assert_received :connected
    end

    test "destroying an unclaimed name is :ok without a delete call" do
      Req.Test.stub(__MODULE__, fn conn ->
        case conn.method do
          "GET" -> Req.Test.json(conn, [])
        end
      end)

      assert :ok = Adapter.destroy(handle())
    end

    test "destroy deletes the resolved sandbox" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"DELETE", "/sandboxes/sbx1"} ->
            send(test, :deleted)
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.destroy(handle())
      assert_received :deleted
    end
  end

  describe "list_all_names/0" do
    test "follows x-next-token pagination and returns the full set" do
      Req.Test.stub(__MODULE__, fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        case conn.query_params["nextToken"] do
          nil ->
            conn
            |> Plug.Conn.put_resp_header("x-next-token", "page2")
            |> Req.Test.json([listed("running", "a")])

          "page2" ->
            Req.Test.json(conn, [
              %{
                "sandboxID" => "b",
                "state" => "paused",
                "metadata" => %{"fountain_name" => "fountain-second"}
              }
            ])
        end
      end)

      assert {:ok, names} = Adapter.list_all_names()
      assert names == MapSet.new([@name, "fountain-second"])
    end
  end

  describe "exec/4 — the Connect streaming path end to end" do
    test "collects stdout and the exit code through the CommandServer" do
      body =
        stream_body([
          %{"event" => %{"start" => %{"pid" => 42}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("he")}}},
          %{"event" => %{"data" => %{"stdout" => Base.encode64("llo")}}},
          %{"event" => %{"data" => %{"stderr" => Base.encode64("dropped")}}},
          %{"event" => %{"end" => %{"exitCode" => 3}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"POST", "/process.Process/Start"} ->
            Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, "hello", 3} = Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "a paused sandbox is resumed before the exec reaches envd" do
      test = self()
      body = stream_body([%{"event" => %{"end" => %{"exitCode" => 0}}}])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("paused")])

          {"POST", "/sandboxes/sbx1/connect"} ->
            send(test, :connected)
            Req.Test.json(conn, %{})

          {"POST", "/process.Process/Start"} ->
            Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, "", 0} = Adapter.exec(handle(), "true", [], [])
      assert_received :connected
    end
  end

  describe "spawn/4 and stdin" do
    test "spawn delivers frames to the owner and write_stdin is total after exit" do
      body =
        stream_body([
          %{"event" => %{"data" => %{"stdout" => Base.encode64("ready")}}},
          %{"event" => %{"end" => %{"exitCode" => 0}}}
        ])

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} -> Req.Test.json(conn, [listed("running")])
          {"POST", "/process.Process/Start"} -> Plug.Conn.resp(conn, 200, body)
        end
      end)

      assert {:ok, %Command{provider: :e2b, ref: ref} = command} =
               Adapter.spawn(handle(), "claude-agent-acp", [], owner: self(), stdin: true)

      assert_receive {:stdout, %{ref: ^ref}, "ready"}, 1_000
      assert_receive {:exit, %{ref: ^ref}, 0}, 1_000

      # The CommandServer stopped with the stream; a late write must come
      # back as an error rather than exiting the caller (#603 semantics).
      wait_for_down(command.private.pid)
      assert {:error, :command_exited} = Adapter.write_stdin(command, "late\n")
    end
  end

  describe "network policy" do
    test "allow: [] sends the explicit deny-all body — never a no-op" do
      test = self()

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/v2/sandboxes"} ->
            Req.Test.json(conn, [listed("running")])

          {"PUT", "/sandboxes/sbx1/network"} ->
            {:ok, raw, conn} = Plug.Conn.read_body(conn)
            send(test, {:network, Jason.decode!(raw)})
            Req.Test.json(conn, %{})
        end
      end)

      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []})
      assert_received {:network, %{"denyOut" => ["0.0.0.0/0"], "allowOut" => []}}
    end
  end

  describe "capabilities" do
    test "suspend and network policy are real; checkpoints are refused" do
      caps = Adapter.capabilities()
      assert MapSet.member?(caps, :suspend)
      assert MapSet.member?(caps, :network_policy)
      assert MapSet.member?(caps, :attach)
      refute MapSet.member?(caps, :checkpoint)

      assert {:error, :not_supported} = Adapter.create_checkpoint(handle(), [])
      assert {:error, :not_supported} = Adapter.restore_checkpoint(handle(), "cp")
    end
  end

  defp wait_for_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      1_000 -> flunk("command server did not stop")
    end
  end
end
