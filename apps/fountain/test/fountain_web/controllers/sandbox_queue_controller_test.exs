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
    for _ <- 1..Fountain.Quotas.sandbox_limit(user.id) do
      insert_sandbox(user_id: user.id, status: "ready")
    end
  end

  test "POST with queue true answers 202 at the cap", context do
    fill_cap(context.user)

    conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> post_json("/api/conversations", %{
        agent_id: context.agent.id,
        prompt: "queued work",
        queue: true
      })

    assert %{"data" => %{"status" => "queued", "position" => 1}} = json_response(conn, 202)
    assert [request] = SandboxQueue.list_queued(context.user.id)
    assert request.attrs["prompt"] == "queued work"
  end

  test "only the launch keys are kept on the queued request", context do
    fill_cap(context.user)

    conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> post_json("/api/conversations", %{
        agent_id: context.agent.id,
        prompt: "queued work",
        title: "a title",
        queue: true,
        # `ConversationCreateRequest` does not set additionalProperties: false,
        # so anything a caller sends arrives here. None of it belongs in a row
        # that sits in the table for an hour.
        junk: %{"anything" => String.duplicate("x", 100)},
        user_id: Ecto.UUID.generate()
      })

    assert json_response(conn, 202)
    assert [request] = SandboxQueue.list_queued(context.user.id)
    # `parent_conversation_id` is one the controller itself puts on every
    # launch; `junk` and the spoofed `user_id` are the point.
    assert request.attrs ==
             %{
               "prompt" => "queued work",
               "title" => "a title",
               "parent_conversation_id" => nil
             }

    assert request.user_id == context.user.id
  end

  test "POST without queue keeps the existing 429 contract", context do
    fill_cap(context.user)

    conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> post_json("/api/conversations", %{agent_id: context.agent.id})

    assert %{"error" => "sandbox_quota_exceeded"} = json_response(conn, 429)
    assert SandboxQueue.list_queued(context.user.id) == []
  end

  test "image and explicit-sandbox requests never queue", context do
    fill_cap(context.user)

    png =
      Base.encode64(<<137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1>>)

    conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> post_json("/api/conversations", %{
        agent_id: context.agent.id,
        queue: true,
        images: [%{data: png, media_type: "image/png"}]
      })

    assert json_response(conn, 429)
    assert SandboxQueue.list_queued(context.user.id) == []
  end

  test "GET lists only the caller's work in position order", context do
    {:ok, first} =
      SandboxQueue.enqueue(%{
        user_id: context.user.id,
        agent_id: context.agent.id,
        kind: "start",
        attrs: %{}
      })

    {:ok, _second} =
      SandboxQueue.enqueue(%{
        user_id: context.user.id,
        agent_id: context.agent.id,
        kind: "start",
        attrs: %{}
      })

    conn = context.conn |> authed_with_key(context.raw_key) |> get("/api/sandbox-queue")

    assert [%{"position" => 1, "id" => id}, %{"position" => 2}] =
             json_response(conn, 200)["data"]

    assert id == first.id
  end

  test "DELETE cancels a tenant-owned waiting request", context do
    {:ok, request} =
      SandboxQueue.enqueue(%{
        user_id: context.user.id,
        agent_id: context.agent.id,
        kind: "start",
        attrs: %{}
      })

    conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> delete("/api/sandbox-queue/#{request.id}")

    assert response(conn, 204)
    assert SandboxQueue.list_queued(context.user.id) == []

    show_conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> get("/api/sandbox-queue/#{request.id}")

    assert %{"data" => %{"status" => "cancelled", "position" => nil}} =
             json_response(show_conn, 200)
  end

  test "DELETE hides another tenant's request", context do
    other = insert_verified_user()
    agent = insert_agent(user_id: other.id)

    {:ok, request} =
      SandboxQueue.enqueue(%{user_id: other.id, agent_id: agent.id, kind: "start", attrs: %{}})

    conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> delete("/api/sandbox-queue/#{request.id}")

    assert json_response(conn, 404)
    assert [_] = SandboxQueue.list_queued(other.id)
  end

  test "malformed request ids return 404", context do
    show_conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> get("/api/sandbox-queue/not-a-uuid")

    assert json_response(show_conn, 404)

    delete_conn =
      context.conn
      |> authed_with_key(context.raw_key)
      |> delete("/api/sandbox-queue/not-a-uuid")

    assert json_response(delete_conn, 404)
  end
end
