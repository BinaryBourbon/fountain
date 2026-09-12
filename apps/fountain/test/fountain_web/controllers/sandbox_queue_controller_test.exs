defmodule FountainWeb.SandboxQueueControllerTest do
  use FountainWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Fountain.SandboxQueue

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, raw_key: raw_key, agent: agent}
  end

  defp enqueue!(user, agent, extra \\ %{}) do
    {:ok, request} =
      SandboxQueue.enqueue(
        Map.merge(
          %{user_id: user.id, agent_id: agent.id, kind: "start", attrs: %{"prompt" => "hi"}},
          extra
        )
      )

    request
  end

  describe "GET /api/sandbox-queue" do
    test "lists waiting requests in position order", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      first = enqueue!(user, agent)
      second = enqueue!(user, agent)

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/sandbox-queue")
        |> json_response(200)

      assert [one, two] = body["data"]
      assert one["id"] == first.id
      assert one["position"] == 1
      assert two["id"] == second.id
      assert two["position"] == 2
    end

    test "omits a request that is no longer waiting", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      request = enqueue!(user, agent)
      {:ok, _} = SandboxQueue.cancel_request(request)

      body = conn |> authed_with_key(raw_key) |> get("/api/sandbox-queue") |> json_response(200)
      assert body["data"] == []
    end

    test "never lists another tenant's work", %{conn: conn, raw_key: raw_key} do
      other = insert_active_user()
      enqueue!(other, insert_agent(user_id: other.id))

      body = conn |> authed_with_key(raw_key) |> get("/api/sandbox-queue") |> json_response(200)
      assert body["data"] == []
    end

    test "requires a key", %{conn: conn} do
      assert conn |> get("/api/sandbox-queue") |> json_response(401)
    end
  end

  describe "GET /api/sandbox-queue/:id" do
    test "reports a waiting request and its position", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      request = enqueue!(user, agent)

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/sandbox-queue/#{request.id}")
        |> json_response(200)

      assert body["data"]["status"] == "queued"
      assert body["data"]["position"] == 1
    end

    test "reports a terminal outcome and drops the position", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      request = enqueue!(user, agent)
      {:ok, _} = SandboxQueue.cancel_request(request)

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/sandbox-queue/#{request.id}")
        |> json_response(200)

      assert body["data"]["status"] == "cancelled"
      assert body["data"]["position"] == nil
    end

    test "another tenant's request is 404, not 403", %{conn: conn, raw_key: raw_key} do
      other = insert_active_user()
      request = enqueue!(other, insert_agent(user_id: other.id))

      assert conn
             |> authed_with_key(raw_key)
             |> get("/api/sandbox-queue/#{request.id}")
             |> json_response(404)
    end

    test "an id that is not a uuid is 404, not a 500", %{conn: conn, raw_key: raw_key} do
      assert conn
             |> authed_with_key(raw_key)
             |> get("/api/sandbox-queue/nope")
             |> json_response(404)
    end
  end

  describe "DELETE /api/sandbox-queue/:id" do
    test "cancels a waiting request", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      request = enqueue!(user, agent)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/sandbox-queue/#{request.id}")

      assert response(conn, 204)
      assert SandboxQueue.list_queued(user.id) == []
      assert Fountain.Repo.get!(Fountain.SandboxQueue.Request, request.id).status == "cancelled"
    end

    test "cancelling twice is 404 the second time", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      request = enqueue!(user, agent)

      assert conn
             |> authed_with_key(raw_key)
             |> delete("/api/sandbox-queue/#{request.id}")
             |> response(204)

      assert conn
             |> authed_with_key(raw_key)
             |> delete("/api/sandbox-queue/#{request.id}")
             |> json_response(404)
    end

    test "a request the drainer already claimed is 404", %{
      conn: conn,
      user: user,
      raw_key: raw_key,
      agent: agent
    } do
      request = enqueue!(user, agent)

      {1, _} =
        Fountain.Repo.update_all(
          from(r in Fountain.SandboxQueue.Request, where: r.id == ^request.id),
          set: [status: "starting"]
        )

      assert conn
             |> authed_with_key(raw_key)
             |> delete("/api/sandbox-queue/#{request.id}")
             |> json_response(404)

      assert Fountain.Repo.get!(Fountain.SandboxQueue.Request, request.id).status == "starting"
    end

    test "never cancels another tenant's request", %{conn: conn, raw_key: raw_key} do
      other = insert_active_user()
      request = enqueue!(other, insert_agent(user_id: other.id))

      assert conn
             |> authed_with_key(raw_key)
             |> delete("/api/sandbox-queue/#{request.id}")
             |> json_response(404)

      assert Fountain.Repo.get!(Fountain.SandboxQueue.Request, request.id).status == "queued"
    end

    test "records who cancelled it", %{conn: conn, user: user, raw_key: raw_key, agent: agent} do
      request = enqueue!(user, agent)

      conn |> authed_with_key(raw_key) |> delete("/api/sandbox-queue/#{request.id}")

      events = Fountain.Audit.list_for("sandbox_request", request.id, user.id)

      assert event = Enum.find(events, &(&1.action == "sandbox_request.cancelled"))
      assert event.actor == "api"
    end
  end
end
