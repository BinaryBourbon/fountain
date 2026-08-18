defmodule FountainWeb.EventsStreamTest do
  @moduledoc """
  `GET /api/events/stream` — every conversation on one connection — and the
  `?blocks=true` read-model on `/events` and the per-conversation stream.
  Same fast-loop technique as `SseStreamTest`.
  """

  use FountainWeb.ConnCase, async: false

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  @endpoint FountainWeb.Endpoint

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)

    previous = {
      Application.get_env(:fountain, :sse_heartbeat_ms),
      Application.get_env(:fountain, :sse_idle_timeout_ms)
    }

    on_exit(fn ->
      {hb, idle} = previous

      if hb,
        do: Application.put_env(:fountain, :sse_heartbeat_ms, hb),
        else: Application.delete_env(:fountain, :sse_heartbeat_ms)

      if idle,
        do: Application.put_env(:fountain, :sse_idle_timeout_ms, idle),
        else: Application.delete_env(:fountain, :sse_idle_timeout_ms)
    end)

    Application.put_env(:fountain, :sse_heartbeat_ms, 60_000)
    Application.put_env(:fountain, :sse_idle_timeout_ms, 1_500)

    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    {:ok, user: user, raw_key: raw_key}
  end

  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  defp publish(conv, attrs) do
    ev = insert_log_event(conv, attrs)
    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, ev})
    ev
  end

  defp stream_async(raw_key, path, headers \\ []) do
    parent = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())

      conn =
        Enum.reduce(headers, authed_with_key(build_conn(), raw_key), fn {k, v}, c ->
          Plug.Conn.put_req_header(c, k, v)
        end)

      Phoenix.ConnTest.dispatch(conn, @endpoint, :get, path)
    end)
  end

  describe "GET /api/events/stream" do
    test "events from every live conversation, labelled; finished and foreign ones excluded", %{
      user: user,
      raw_key: key
    } do
      a = insert_conversation(user_id: user.id, status: "idle")
      b = insert_conversation(user_id: user.id, status: "running")
      dead = insert_conversation(user_id: user.id, status: "terminated")
      foreign = insert_conversation(user_id: insert_verified_user().id, status: "idle")

      task = stream_async(key, "/api/events/stream")
      Process.sleep(300)

      publish(a, %{kind: "output", stream: "acp", data: "from-a"})
      publish(b, %{kind: "output", stream: "acp", data: "from-b"})
      publish(dead, %{kind: "output", stream: "acp", data: "from-dead"})
      publish(foreign, %{kind: "output", stream: "acp", data: "from-foreign"})

      conn = Task.await(task, 5_000)
      assert conn.status == 200
      assert String.starts_with?(conn.resp_body, ": connected\n\n")
      assert conn.resp_body =~ "from-a"
      assert conn.resp_body =~ "from-b"
      refute conn.resp_body =~ "from-dead"
      refute conn.resp_body =~ "from-foreign"

      [payload] =
        Regex.run(~r/data: (\{[^\n]*from-a[^\n]*\})/, conn.resp_body, capture: :all_but_first)

      assert Jason.decode!(payload)["conversation_id"] == a.id
    end

    test "Last-Event-ID replays what was missed across conversations", %{user: user, raw_key: key} do
      a = insert_conversation(user_id: user.id, status: "idle")
      b = insert_conversation(user_id: user.id, status: "idle")
      seen = insert_log_event(a, %{kind: "output", stream: "acp", data: "seen"})
      insert_log_event(b, %{kind: "output", stream: "acp", data: "missed-b"})
      insert_log_event(a, %{kind: "output", stream: "acp", data: "missed-a"})

      conn =
        stream_async(key, "/api/events/stream", [{"last-event-id", to_string(seen.id)}])
        |> Task.await(5_000)

      refute conn.resp_body =~ "\"seen\""
      assert conn.resp_body =~ "missed-b"
      assert conn.resp_body =~ "missed-a"
    end

    test "a sidebar ping becomes one debounced `conversations` event and follows new ones", %{
      user: user,
      raw_key: key
    } do
      insert_conversation(user_id: user.id, status: "idle")

      task = stream_async(key, "/api/events/stream")
      Process.sleep(300)

      new = insert_conversation(user_id: user.id, status: "idle")

      for _ <- 1..5,
          do:
            Phoenix.PubSub.broadcast(
              Fountain.PubSub,
              "sidebar:#{user.id}",
              {:sidebar_update, user.id}
            )

      # Past the 1 s debounce: the refollow ran, the new conversation is subscribed.
      Process.sleep(1_300)
      publish(new, %{kind: "output", stream: "acp", data: "from-new"})

      conn = Task.await(task, 6_000)
      assert length(Regex.scan(~r/event: conversations\n/, conn.resp_body)) == 1
      assert conn.resp_body =~ "from-new"
    end

    test "?blocks=true adds the server-parsed blocks per event", %{user: user, raw_key: key} do
      a = insert_conversation(user_id: user.id, status: "idle")
      marker = insert_log_event(a, %{kind: "output", stream: "stdout", data: "m"})
      insert_log_event(a, %{kind: "output", stream: "acp", data: acp_text("hello")})

      conn =
        stream_async(key, "/api/events/stream?blocks=true&streams=acp", [
          {"last-event-id", to_string(marker.id)}
        ])
        |> Task.await(5_000)

      [payload] =
        Regex.run(~r/data: (\{[^\n]*hello[^\n]*\})/, conn.resp_body, capture: :all_but_first)

      assert %{"blocks" => [%{"kind" => "text", "body" => "hello"}]} = Jason.decode!(payload)
    end
  end

  describe "?blocks=true on the per-conversation surfaces" do
    test "GET /events adds blocks for output events and [] for stage events", %{
      user: user,
      raw_key: key
    } do
      conv =
        insert_conversation(
          user_id: user.id,
          agent: insert_agent(user_id: user.id, runtime: "claude")
        )

      insert_log_event(conv, %{kind: "output", stream: "acp", data: acp_text("hi")})
      insert_log_event(conv, %{kind: "stage", stream: "", stage: "turn", state: "done"})

      body =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}/events?blocks=true")
        |> json_response(200)

      assert [%{"blocks" => [%{"kind" => "text", "body" => "hi"}]}, %{"blocks" => []}] =
               body["data"]

      # Without the flag the field is absent, so existing clients see the same rows.
      plain =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}/events")
        |> json_response(200)

      refute Map.has_key?(hd(plain["data"]), "blocks")
    end

    test "the per-conversation stream adds blocks with ?blocks=true", %{user: user, raw_key: key} do
      conv =
        insert_conversation(
          user_id: user.id,
          agent: insert_agent(user_id: user.id, runtime: "claude")
        )

      insert_log_event(conv, %{kind: "output", stream: "acp", data: acp_text("streamed")})

      conn =
        stream_async(key, "/api/conversations/#{conv.id}/stream?wait=false&blocks=true")
        |> Task.await(5_000)

      assert conn.resp_body =~ ~s("blocks":[{"body":"streamed","kind":"text"}])
    end
  end
end
