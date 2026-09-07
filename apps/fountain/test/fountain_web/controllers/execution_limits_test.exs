defmodule FountainWeb.ExecutionLimitsTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Accounts, Conversations, Repo}

  setup do
    user = insert_verified_user()
    {_key, raw} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      send(owner, :worker_started)
      {:ok, spawn(fn -> :ok end)}
    end)

    %{user: user, raw: raw, agent: agent}
  end

  defp request(c, attrs, status) do
    c.conn
    |> authed_with_key(c.raw)
    |> post_json("/api/conversations", Map.merge(%{"agent_id" => c.agent.id}, attrs))
    |> json_response(status)
  end

  test "an omitted allowance preserves the current unlimited launch shape", c do
    response = request(c, %{}, 201)
    assert response["data"]["execution_limits"] == %{}
    assert_received :worker_started
  end

  test "unsupported explicit controls refuse before any sandbox or worker is created", c do
    for limits <- [
          %{"wall_time_seconds" => 60},
          %{"max_model_turns" => 3},
          %{"max_estimated_cost_usd" => 0.25}
        ] do
      response = request(c, %{"execution_limits" => limits}, 422)
      assert response["error"] == "execution_limits_unsupported"
      assert response["fields"] == Map.keys(limits)
    end

    assert Repo.aggregate(Conversations.Sandbox, :count) == 0
    assert Repo.aggregate(Conversations.Conversation, :count) == 0
    refute_received :worker_started
  end

  test "inherited account ceilings cannot be bypassed by omission or an empty request", c do
    {:ok, _} = Accounts.update_execution_limits(c.user, %{wall_time_seconds: 60}, actor: "admin")

    for attrs <- [%{}, %{"execution_limits" => %{}}] do
      response = request(c, attrs, 422)
      assert response["error"] == "execution_limits_unsupported"
      assert response["fields"] == ["wall_time_seconds"]
    end

    assert Repo.aggregate(Conversations.Sandbox, :count) == 0
    refute_received :worker_started
  end

  test "a client cannot widen its account ceiling or borrow another user's policy", c do
    {:ok, _} = Accounts.update_execution_limits(c.user, %{wall_time_seconds: 30})
    other = insert_verified_user()

    response =
      request(
        c,
        %{"user_id" => other.id, "execution_limits" => %{"wall_time_seconds" => 60}},
        422
      )

    assert response["error"] == "execution_limits_widen"
    assert response["field"] == "wall_time_seconds"
    assert Repo.aggregate(Conversations.Sandbox, :count) == 0
    refute_received :worker_started
  end

  test "null fields, unknown metadata and numeric strings are rejected at HTTP validation", c do
    for limits <- [
          %{"wall_time_seconds" => nil},
          %{"max_model_turns" => "5"},
          %{"_meta" => %{}},
          %{"max_estimated_cost_usd" => -1}
        ] do
      response = request(c, %{"execution_limits" => limits}, 422)
      assert response["error"] in ["validation_failed", "execution_limits_invalid"]
    end

    assert Repo.aggregate(Conversations.Sandbox, :count) == 0
    refute_received :worker_started
  end

  test "a bound channel cannot reset or widen its saved allowance", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: c.user.id,
        agent: c.agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "bounded",
        execution_limits: %{"wall_time_seconds" => 20}
      )

    response =
      request(
        c,
        %{"channel_id" => "bounded", "execution_limits" => %{"wall_time_seconds" => 60}},
        422
      )

    assert response["error"] == "execution_limits_widen"

    assert Conversations.get_conversation(conv.id, c.user.id).execution_limits == %{
             "wall_time_seconds" => 20
           }

    refute_received :worker_started
  end

  test "a refused fresh request preserves the existing channel binding", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: c.user.id,
        agent: c.agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "bound"
      )

    response =
      request(
        c,
        %{
          "channel_id" => "bound",
          "fresh" => true,
          "execution_limits" => %{"wall_time_seconds" => 60}
        },
        422
      )

    assert response["error"] == "execution_limits_unsupported"
    assert Conversations.get_conversation(conv.id, c.user.id).channel_id == "bound"
    assert Repo.aggregate(Conversations.Sandbox, :count) == 1
    refute_received :worker_started
  end

  test "a new prompt cannot bypass a ceiling configured after conversation creation", c do
    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")

    conv =
      insert_conversation(user_id: c.user.id, agent: c.agent, sandbox: sandbox, status: "idle")

    {:ok, _} = Accounts.update_execution_limits(c.user, %{wall_time_seconds: 60})

    response =
      c.conn
      |> authed_with_key(c.raw)
      |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "must not start"})
      |> json_response(422)

    assert response["error"] == "execution_limits_unsupported"
    assert Repo.aggregate(Conversations.Turn, :count) == 0
    refute_received :worker_started
  end

  test "turn reads expose the persisted limit outcome and partial usage", c do
    alias Fountain.Conversations.ExecutionGuard
    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")

    conv =
      insert_conversation(user_id: c.user.id, agent: c.agent, sandbox: sandbox, status: "running")

    now = DateTime.utc_now() |> DateTime.truncate(:second)
    turn = insert_turn(conv, status: "running", started_at: now, usage: %{"input" => 42})
    deadline = DateTime.add(now, 60)
    {:ok, execution} = ExecutionGuard._unsafe_register(turn.id, Ecto.UUID.generate(), deadline)
    {:ok, _} = ExecutionGuard._unsafe_expire(execution.id, now: deadline)

    response =
      c.conn
      |> authed_with_key(c.raw)
      |> get("/api/conversations/#{conv.id}/turns")
      |> json_response(200)

    assert [row] = response["data"]
    assert row["status"] == "failed"
    assert row["limit_reason"] == "wall_time_limit"
    assert row["exit_code"] == nil
    assert row["usage"]["input"] == 42
  end

  test "attaching to an existing sandbox does not bypass the limit gate", c do
    sandbox = insert_sandbox(user_id: c.user.id, agent_id: c.agent.id, status: "ready")

    response =
      request(
        c,
        %{"sandbox_id" => sandbox.id, "execution_limits" => %{"wall_time_seconds" => 60}},
        422
      )

    assert response["error"] == "execution_limits_unsupported"
    assert Repo.aggregate(Conversations.Conversation, :count) == 0
    refute_received :worker_started
  end
end
