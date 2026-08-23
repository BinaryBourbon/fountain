defmodule FountainWeb.SandboxQueueControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.SandboxQueue

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  defp fill_cap(user) do
    limit = Fountain.Quotas.default_limit()
    for _ <- 1..limit, do: insert_sandbox(user_id: user.id, status: "ready")
    limit
  end

  describe "POST /api/conversations with queue: true (ADR 0030)" do
    test "at the cap, queues and answers 202 with a position", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      fill_cap(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          agent_id: agent.id,
          prompt: "queued work",
          queue: true
        })

      body = json_response(conn, 202)
      assert body["data"]["status"] == "queued"
      assert body["data"]["kind"] == "start"
      assert body["data"]["agent_id"] == agent.id
      assert body["data"]["position"] == 1

      [request] = SandboxQueue.list_queued(user.id)
      assert request.attrs["prompt"] == "queued work"
    end

    test "without the flag the cap still refuses with 429", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      fill_cap(user)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{agent_id: agent.id})

      assert %{"error" => "sandbox_quota_exceeded"} = json_response(conn, 429)
      assert SandboxQueue.list_queued(user.id) == []
    end

    test "past the queue's depth bound the caller gets the 429 it opted out of", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      fill_cap(user)
      Application.put_env(:fountain, :sandbox_queue_max_depth, 0)
      on_exit(fn -> Application.delete_env(:fountain, :sandbox_queue_max_depth) end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{agent_id: agent.id, queue: true})

      assert %{"error" => "sandbox_quota_exceeded"} = json_response(conn, 429)
    end

    test "requests carrying images are refused, never queued", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      fill_cap(user)

      png =
        Base.encode64(
          <<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1>>
        )

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          agent_id: agent.id,
          queue: true,
          images: [%{data: png, media_type: "image/png"}]
        })

      assert json_response(conn, 429)
      assert SandboxQueue.list_queued(user.id) == []
    end
  end

  describe "GET /api/sandbox-queue" do
    test "lists the caller's queued requests in position order", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      {:ok, first} =
        SandboxQueue.enqueue(%{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{}})

      {:ok, _second} =
        SandboxQueue.enqueue(%{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{}})

      other = insert_verified_user()
      other_agent = insert_agent(user_id: other.id)

      {:ok, _} =
        SandboxQueue.enqueue(%{
          user_id: other.id,
          agent_id: other_agent.id,
          kind: "start",
          attrs: %{}
        })

      conn = conn |> authed_with_key(raw_key) |> get("/api/sandbox-queue")

      body = json_response(conn, 200)
      assert [%{"position" => 1, "id" => id1}, %{"position" => 2}] = body["data"]
      assert id1 == first.id
    end
  end

  describe "DELETE /api/sandbox-queue/:id" do
    test "cancels a queued request", %{conn: conn, user: user, raw_key: raw_key, agent: agent} do
      {:ok, request} =
        SandboxQueue.enqueue(%{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{}})

      conn = conn |> authed_with_key(raw_key) |> delete("/api/sandbox-queue/#{request.id}")

      assert response(conn, 204)
      assert SandboxQueue.list_queued(user.id) == []
    end

    test "404s on another tenant's request", %{conn: conn, raw_key: raw_key} do
      other = insert_verified_user()
      other_agent = insert_agent(user_id: other.id)

      {:ok, request} =
        SandboxQueue.enqueue(%{
          user_id: other.id,
          agent_id: other_agent.id,
          kind: "start",
          attrs: %{}
        })

      conn = conn |> authed_with_key(raw_key) |> delete("/api/sandbox-queue/#{request.id}")

      assert json_response(conn, 404)
      assert [_still_queued] = SandboxQueue.list_queued(other.id)
    end

    test "404s on a request that already left the queue", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      {:ok, request} =
        SandboxQueue.enqueue(%{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{}})

      {:ok, _} = SandboxQueue.cancel_request(request)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/sandbox-queue/#{request.id}")

      assert json_response(conn, 404)
    end
  end
end
