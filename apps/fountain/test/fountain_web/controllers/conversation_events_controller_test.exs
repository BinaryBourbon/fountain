defmodule FountainWeb.ConversationEventsControllerTest do
  @moduledoc """
  The JSON read-model for a conversation's log feed (#519).

  Before this, the only access to log events over the API was the SSE stream —
  so anything wanting to fetch, archive or analyse a conversation's output had
  to implement an event-stream parser for what is a paginated list read.
  """

  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    conv = insert_conversation(user_id: user.id)
    {:ok, user: user, key: key, conv: conv}
  end

  defp get_events(conn, key, conv, query \\ "") do
    conn |> authed_with_key(key) |> get("/api/conversations/#{conv.id}/events" <> query)
  end

  describe "GET /api/conversations/:id/events" do
    test "returns the feed oldest-first with the SSE payload's fields", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      first = insert_log_event(conv, kind: "output", stream: "stdout", data: "hello")
      second = insert_log_event(conv, kind: "stage", stream: "", stage: "provision")

      body = conn |> get_events(key, conv) |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [first.id, second.id]

      assert %{
               "id" => _,
               "kind" => "output",
               "stream" => "stdout",
               "data" => "hello",
               "stage" => _,
               "state" => _,
               "duration_ms" => _,
               "turn_id" => _,
               "ts" => _
             } = hd(body["data"])
    end

    test "an empty feed is an empty page, not an error", %{conn: conn, key: key, conv: conv} do
      body = conn |> get_events(key, conv) |> json_response(200)

      assert body["data"] == []
      assert body["meta"]["has_more"] == false
      assert body["meta"]["next_cursor"] == nil
    end

    test "filters by stream, with the same semantics as the SSE route", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      out = insert_log_event(conv, kind: "output", stream: "stdout", data: "o")
      err = insert_log_event(conv, kind: "output", stream: "stderr", data: "e")
      stage = insert_log_event(conv, kind: "stage", stream: "", stage: "boot")

      ids = fn query ->
        conn |> get_events(key, conv, query) |> json_response(200) |> Map.fetch!("data")
      end

      assert ids.("?streams=stdout") |> Enum.map(& &1["id"]) == [out.id]
      assert ids.("?streams=stage") |> Enum.map(& &1["id"]) == [stage.id]

      assert ids.("?streams=stderr,stage") |> Enum.map(& &1["id"]) == [err.id, stage.id]
    end

    test "an unknown stream name returns nothing rather than everything", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      insert_log_event(conv, kind: "output", stream: "stdout")

      body = conn |> get_events(key, conv, "?streams=bogus") |> json_response(200)
      assert body["data"] == []
    end
  end

  describe "pagination" do
    test "pages through the feed with next_cursor", %{conn: conn, key: key, conv: conv} do
      events = for i <- 1..5, do: insert_log_event(conv, data: "line #{i}")
      ids = Enum.map(events, & &1.id)

      page1 = conn |> get_events(key, conv, "?limit=2") |> json_response(200)
      assert Enum.map(page1["data"], & &1["id"]) == Enum.take(ids, 2)
      assert page1["meta"]["has_more"]
      assert page1["meta"]["next_cursor"] == Enum.at(ids, 1)

      page2 =
        conn
        |> get_events(key, conv, "?limit=2&after=#{page1["meta"]["next_cursor"]}")
        |> json_response(200)

      assert Enum.map(page2["data"], & &1["id"]) == Enum.slice(ids, 2, 2)
      assert page2["meta"]["has_more"]

      page3 =
        conn
        |> get_events(key, conv, "?limit=2&after=#{page2["meta"]["next_cursor"]}")
        |> json_response(200)

      assert Enum.map(page3["data"], & &1["id"]) == [List.last(ids)]

      # The last page must say so — a client that keeps following has_more
      # would loop forever on a finished conversation.
      refute page3["meta"]["has_more"]
    end

    test "the limit is capped so a huge feed cannot be pulled in one request", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      insert_log_event(conv)

      body = conn |> get_events(key, conv, "?limit=99999") |> json_response(200)
      assert body["meta"]["limit"] == 1000
    end

    test "a zero or negative limit clamps to one page of one", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      insert_log_event(conv)

      assert conn |> get_events(key, conv, "?limit=0") |> json_response(200) |> get_in([
               "meta",
               "limit"
             ]) == 1

      assert conn |> get_events(key, conv, "?limit=-5") |> json_response(200) |> get_in([
               "meta",
               "limit"
             ]) == 1
    end

    test "a non-numeric limit is refused by the spec", %{conn: conn, key: key, conv: conv} do
      conn |> get_events(key, conv, "?limit=abc") |> json_response(422)
    end

    test "has_more accounts for the stream filter, not just the raw feed", %{
      conn: conn,
      key: key,
      conv: conv
    } do
      # Two stdout rows either side of noise: paging over a filtered feed must
      # not report more pages because of rows the filter removed.
      a = insert_log_event(conv, kind: "output", stream: "stdout", data: "a")
      insert_log_event(conv, kind: "output", stream: "stderr", data: "noise")
      b = insert_log_event(conv, kind: "output", stream: "stdout", data: "b")

      body = conn |> get_events(key, conv, "?streams=stdout&limit=2") |> json_response(200)

      assert Enum.map(body["data"], & &1["id"]) == [a.id, b.id]
      refute body["meta"]["has_more"]
    end
  end

  describe "tenant scoping" do
    test "another tenant's conversation is 404, not 403", %{conn: conn, key: key} do
      other = insert_verified_user()
      other_conv = insert_conversation(user_id: other.id)
      insert_log_event(other_conv, data: "secret output")

      conn =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{other_conv.id}/events")

      assert json_response(conn, 404)
      refute conn.resp_body =~ "secret output"
    end

    test "requires authentication", %{conn: conn, conv: conv} do
      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/conversations/#{conv.id}/events")
      |> json_response(401)
    end
  end
end
