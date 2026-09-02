defmodule Fountain.TimeoutTransport do
  def request("GET", url, _headers, _body, _timeout) do
    cond do
      String.ends_with?(url, "/api/agents") ->
        {:ok, 200, [], Jason.encode!(%{"data" => [%{"id" => "agent-1", "name" => "writer"}]})}

      String.ends_with?(url, "/api/conversations/c2") ->
        {:ok, 200, [], Jason.encode!(%{"data" => %{"id" => "c2", "status" => "running"}})}
    end
  end

  def request("POST", _url, _headers, _body, _timeout),
    do: {:ok, 201, [], Jason.encode!(%{"data" => %{"id" => "c2", "status" => "running"}})}

  def stream("GET", _url, _headers, _timeout, on_chunk) do
    on_chunk.(
      "id: 1\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1}}\n\nid: 2\nevent: output\ndata: {\"stream\":\"acp\",\"blocks\":[{\"kind\":\"text\",\"body\":\"partial\"}]}\n\n"
    )

    Process.sleep(500)
    {:error, :timeout}
  end
end

defmodule Fountain.GatedRunTransport do
  def request("GET", url, _headers, _body, _timeout) do
    cond do
      String.ends_with?(url, "/api/agents") ->
        {:ok, 200, [], Jason.encode!(%{"data" => [%{"id" => "agent-1", "name" => "writer"}]})}

      String.ends_with?(url, "/api/conversations/gated") ->
        {:ok, 200, [], Jason.encode!(%{"data" => %{"id" => "gated", "status" => "done"}})}
    end
  end

  def request("POST", _url, _headers, _body, _timeout),
    do: {:ok, 201, [], Jason.encode!(%{"data" => %{"id" => "gated", "status" => "running"}})}

  def stream("GET", _url, _headers, _timeout, on_chunk) do
    owner = :persistent_term.get({__MODULE__, :owner})
    send(owner, {:gated_stream_ready, self()})

    receive do
      :emit -> :ok
    end

    on_chunk.(
      IO.iodata_to_binary([
        "id: 1\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"started\",\"data\":{\"turn_number\":1}}\n\n",
        "id: 2\nevent: output\ndata: {\"stream\":\"acp\",\"blocks\":[{\"kind\":\"text\",\"body\":\"one\"}]}\n\n",
        "id: 3\nevent: output\ndata: {\"stream\":\"acp\",\"blocks\":[{\"kind\":\"text\",\"body\":\"two\"}]}\n\n"
      ])
    )

    send(owner, {:gated_events_emitted, self()})

    receive do
      :finish -> :ok
    end

    on_chunk.(
      "id: 4\nevent: stage\ndata: {\"stage\":\"turn\",\"state\":\"done\",\"data\":{\"turn_number\":1}}\n\n"
    )

    {:ok, 200, [], nil}
  end
end

defmodule Fountain.RunTest do
  use ExUnit.Case
  alias Fountain.{Error, Run}

  test "run starts immediately and broadcasts one underlying turn to late consumers" do
    parent = self()

    server =
      Fountain.TestServer.start(fn request ->
        send(parent, {:request, request})

        case {request.method, request.path} do
          {"GET", "/api/agents"} ->
            json(200, %{"data" => [%{"id" => "agent-1", "name" => "writer"}]})

          {"POST", "/api/conversations"} ->
            json(201, %{"data" => %{"id" => "c1", "status" => "running"}})

          {"GET", "/api/conversations/c1/stream"} ->
            {200, [{"content-type", "text/event-stream"}], run_events()}

          {"GET", "/api/conversations/c1"} ->
            json(200, %{"data" => %{"id" => "c1", "status" => "done"}})
        end
      end)

    on_exit(fn -> Fountain.TestServer.stop(server) end)
    client = Fountain.new(api_key: "key", base_url: server.url, app_url: "")
    run = Fountain.run(client, "hello", agent: "writer", collect_events: true)

    assert_receive {:request, %{method: "POST", path: "/api/conversations"}}, 1_000
    assert {:ok, result} = Run.await(run)
    assert result.conversation_id == "c1"
    assert result.text == "Hello\n\nworld"
    assert result.tools_used == ["search"]
    assert result.state == :done
    assert length(result.events) == 4

    events_one = Enum.to_list(Run.stream(run))
    events_two = Enum.to_list(Run.stream(run))
    assert events_one == events_two
    assert Enum.map(Enum.to_list(Run.text_stream(run)), & &1) == ["Hello", "\n\nworld"]
  end

  test "run timeout preserves conversation id and partial text" do
    client =
      Fountain.new(
        api_key: "key",
        base_url: "https://example.test",
        app_url: "",
        transport: Fountain.TimeoutTransport
      )

    run = Fountain.run(client, "hello", agent: "writer", timeout: 150)

    assert {:error, %Error{kind: :timeout, conversation_id: "c2", partial_text: "partial"}} =
             Run.await(run)
  end

  test "run server and worker are cleaned up when their owner exits" do
    parent = self()

    owner =
      spawn(fn ->
        run = Run.new(%{}, fn -> Process.sleep(:infinity) end)
        send(parent, {:run_server, run.server})
      end)

    monitor = Process.monitor(owner)
    assert_receive {:run_server, server}
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    server_monitor = Process.monitor(server)
    assert_receive {:DOWN, ^server_monitor, :process, ^server, reason}, 1_000
    assert reason in [:normal, :noproc]
  end

  test "a stream held in another process raises instead of hanging when the run ends" do
    parent = self()

    owner =
      spawn(fn ->
        run = Run.new(%{}, fn -> Process.sleep(:infinity) end)
        send(parent, {:run, run})
        Process.sleep(:infinity)
      end)

    assert_receive {:run, run}

    consumer =
      Task.async(fn ->
        try do
          {:finished, Enum.to_list(Run.stream(run))}
        rescue
          error -> {:raised, error}
        end
      end)

    # The moduledoc invites passing the handle to consumers. When the owner goes
    # away the server stops `:normal`, and without a monitor the consumer's
    # `receive` waits on a mailbox nothing will ever post to again.
    wait_for_subscribers(run.server, 1)
    Process.exit(owner, :kill)

    assert {:raised, %Error{kind: :connection}} = Task.await(consumer, 2_000)
  end

  test "halting one live stream cannot duplicate queued events in a later subscription" do
    :persistent_term.put({Fountain.GatedRunTransport, :owner}, self())
    on_exit(fn -> :persistent_term.erase({Fountain.GatedRunTransport, :owner}) end)

    client =
      Fountain.new(
        api_key: "key",
        base_url: "https://example.test",
        transport: Fountain.GatedRunTransport
      )

    run = Fountain.run(client, "hello", agent: "writer")
    assert_receive {:gated_stream_ready, producer}

    consumer =
      Task.async(fn ->
        first = Enum.take(Run.text_stream(run), 1)
        send(self_owner(), {:first_stream_halted, self()})
        second = Enum.to_list(Run.text_stream(run))
        messages = self() |> Process.info(:messages) |> elem(1)
        {first, second, messages}
      end)

    wait_for_subscribers(run.server, 1)
    send(producer, :emit)
    consumer_pid = consumer.pid
    assert_receive {:first_stream_halted, ^consumer_pid}
    assert_receive {:gated_events_emitted, ^producer}
    wait_for_subscribers(run.server, 1)
    send(producer, :finish)

    assert {["one"], ["one", "two"], messages} = Task.await(consumer)
    refute Enum.any?(messages, &match?({:fountain_run, _, _, _}, &1))
    assert {:ok, %{text: "onetwo"}} = Run.await(run)
  end

  defp self_owner, do: :persistent_term.get({Fountain.GatedRunTransport, :owner})

  defp wait_for_subscribers(server, count, attempts \\ 100)
  defp wait_for_subscribers(_server, _count, 0), do: flunk("subscriber count did not settle")

  defp wait_for_subscribers(server, count, attempts) do
    if map_size(:sys.get_state(server).subscribers) == count do
      :ok
    else
      Process.sleep(5)
      wait_for_subscribers(server, count, attempts - 1)
    end
  end

  defp json(status, value),
    do: {status, [{"content-type", "application/json"}], Jason.encode!(value)}

  defp run_events do
    [
      sse(1, "stage", %{
        "stage" => "turn",
        "state" => "started",
        "data" => %{"turn_number" => 1, "turn_id" => "t1"}
      }),
      sse(2, "output", %{
        "turn_id" => "t1",
        "stream" => "acp",
        "blocks" => [
          %{"kind" => "text", "body" => "Hello"},
          %{"kind" => "tool_use", "name" => "search"}
        ]
      }),
      sse(3, "output", %{
        "turn_id" => "t1",
        "stream" => "acp",
        "blocks" => [%{"kind" => "text", "body" => "world"}]
      }),
      sse(4, "stage", %{
        "stage" => "turn",
        "state" => "done",
        "data" => %{"turn_number" => 1, "turn_id" => "t1", "exit_code" => 0}
      })
    ]
  end

  defp sse(id, event, data), do: "id: #{id}\nevent: #{event}\ndata: #{Jason.encode!(data)}\n\n"
end
