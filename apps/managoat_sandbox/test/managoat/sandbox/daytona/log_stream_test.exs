defmodule Managoat.Sandbox.Daytona.LogStreamTest do
  use ExUnit.Case, async: false

  alias Managoat.Sandbox.Daytona.LogStream

  defp set_req_test_to_shared(context), do: Req.Test.set_req_test_to_shared(context)

  describe "polling loop" do
    setup :set_req_test_to_shared

    setup do
      previous = Application.get_env(:managoat_sandbox, Managoat.Sandbox.Daytona, [])

      Application.put_env(
        :managoat_sandbox,
        Managoat.Sandbox.Daytona,
        Keyword.merge(previous,
          api_key: "dtn_test_key",
          req_options: [plug: {Req.Test, __MODULE__}]
        )
      )

      on_exit(fn ->
        Application.put_env(:managoat_sandbox, Managoat.Sandbox.Daytona, previous)
      end)

      :ok
    end

    test "emits only unseen bytes per fetch, exits from the sentinel, drains the tail" do
      # A journal that grows between polls, served in full each time — the
      # daemon has no Range support and its websocket is not to be trusted.
      {:ok, journal} = Agent.start_link(fn -> {<<1, 1, 1>> <> "one", nil} end)

      Req.Test.stub(__MODULE__, fn conn ->
        case {conn.method, conn.request_path} do
          {"GET", "/toolbox/sbx1/process/session/fountain-1/command/c1/logs"} ->
            {body, _} = Agent.get(journal, & &1)
            Plug.Conn.resp(conn, 200, body)

          {"GET", "/toolbox/sbx1/process/session/fountain-1/command/c1"} ->
            Req.Test.json(conn, %{"id" => "c1"})

          {"POST", "/toolbox/sbx1/process/execute"} ->
            {_, code} = Agent.get(journal, & &1)

            case code do
              nil -> Req.Test.json(conn, %{"result" => "", "exitCode" => 1})
              code -> Req.Test.json(conn, %{"result" => "#{code}\n", "exitCode" => 0})
            end
        end
      end)

      ref = make_ref()

      {:ok, pid} =
        LogStream.start(
          toolbox_url: "https://proxy.test/toolbox/sbx1",
          session_id: "fountain-1",
          command_id: "c1",
          exit_file: "/tmp/fountain/fountain-1.code",
          ref: ref,
          owner: self()
        )

      monitor = Process.monitor(pid)

      assert_receive {:stdout, %{ref: ^ref}, "one"}, 3_000

      # Grow the journal: only the delta may arrive, never a replayed prefix.
      Agent.update(journal, fn {body, code} -> {body <> "two" <> <<2, 2, 2>> <> "err", code} end)
      assert_receive {:stdout, %{ref: ^ref}, "two"}, 3_000
      assert_receive {:stderr, %{ref: ^ref}, "err"}, 3_000

      # The sentinel appears with a final unfetched byte: the drain must
      # deliver it before the terminal frame.
      Agent.update(journal, fn {body, _} -> {body <> <<1, 1, 1>> <> "!", 7} end)
      assert_receive {:exit, %{ref: ^ref}, 7}, 5_000
      assert_received {:stdout, %{ref: ^ref}, "!"}

      assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 3_000
      refute_received {:stdout, _, _}
    end
  end

  describe "demux/2 — the 3-byte channel markers" do
    test "splits a mixed chunk into stdout and stderr segments" do
      data = <<1, 1, 1>> <> "out" <> <<2, 2, 2>> <> "err" <> <<1, 1, 1>> <> "more"

      assert {[{:stdout, "out"}, {:stderr, "err"}, {:stdout, "more"}], :stdout, <<>>} =
               LogStream.demux(data, :stdout)
    end

    test "data before any marker rides the current channel" do
      assert {[{:stderr, "tail"}], :stderr, <<>>} = LogStream.demux("tail", :stderr)
    end

    test "a marker split across chunks is carried, not corrupted" do
      # Chunk one ends mid-marker; the carry must be prepended to chunk two.
      {segments, stream, carry} = LogStream.demux("out" <> <<2, 2>>, :stdout)
      assert segments == [{:stdout, "out"}]
      assert carry == <<2, 2>>

      assert {[{:stderr, "err"}], :stderr, <<>>} =
               LogStream.demux(carry <> <<2>> <> "err", stream)
    end

    test "marker-like bytes inside data survive when not a full marker" do
      # A lone 0x01 followed by ordinary data is content, not a channel switch.
      data = <<1>> <> "x"
      assert {[{:stdout, <<1, ?x>>}], :stdout, <<>>} = LogStream.demux(data, :stdout)
    end

    test "empty input is empty output" do
      assert {[], :stdout, <<>>} = LogStream.demux(<<>>, :stdout)
    end
  end
end
