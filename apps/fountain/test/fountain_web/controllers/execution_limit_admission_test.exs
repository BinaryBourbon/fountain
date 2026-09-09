defmodule FountainWeb.ExecutionLimitAdmissionTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{Conversation, Sandbox}

  setup do
    user = insert_active_user()
    {:ok, user} = Fountain.Accounts.update_sandbox_limit(user, 20)
    {_key, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        status: "ready"
      )

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle",
        channel_id: "limits"
      )

    owner = self()

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      send(owner, :worker_started)
      {:ok, spawn(fn -> :ok end)}
    end)

    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox, conv: conv}
  end

  for path <- [:fresh, :attach, :resume, :rotate] do
    test "#{path} refuses unenforced limits before changing state", ctx do
      before_counts = counts()
      attrs = Map.put(attrs(ctx, unquote(path)), "execution_limits", %{"wall_time_seconds" => 60})
      response = request(ctx, attrs) |> json_response(422)
      assert response["error"] == "execution_limits_unsupported"
      assert response["message"] =~ "wall_time_seconds"
      assert counts() == before_counts
      assert Repo.reload!(ctx.conv).channel_id == "limits"
      refute_received :worker_started
    end
  end

  test "all allowlisted controls are refused until enforcement is integrated", ctx do
    for field <- Conversations.ExecutionLimits.keys() do
      params = Map.put(attrs(ctx, :fresh), "execution_limits", %{field => 1})

      assert %{"error" => "execution_limits_unsupported"} =
               request(ctx, params) |> json_response(422)
    end

    refute_received :worker_started
  end

  test "invalid limits fail with a stable error without echoing input", ctx do
    before_counts = counts()

    for limits <- [
          %{"secret" => "do-not-echo"},
          %{"wall_time_seconds" => "60"},
          %{"max_model_turns" => nil},
          []
        ] do
      params = Map.put(attrs(ctx, :fresh), "execution_limits", limits)
      response = request(ctx, params) |> json_response(422)
      assert response["error"] == "execution_limits_invalid"
      refute Jason.encode!(response) =~ "do-not-echo"
    end

    assert counts() == before_counts
    refute_received :worker_started
  end

  test "direct context callers cannot bypass fresh or attach admission", ctx do
    before_counts = counts()

    for path <- [:fresh, :attach] do
      params =
        attrs(ctx, path)
        |> Map.put("user_id", ctx.user.id)
        |> Map.put("execution_limits", %{max_model_turns: 1})

      assert {:error, {:execution_limits_unsupported, ["max_model_turns"]}} =
               Conversations.start_conversation(params)
    end

    assert counts() == before_counts
    refute_received :worker_started
  end

  test "omitted and empty limits preserve ordinary admission", ctx do
    for limits <- [:omitted, nil, %{}], path <- [:fresh, :attach, :resume] do
      params = attrs(ctx, path)

      params =
        if limits == :omitted, do: params, else: Map.put(params, "execution_limits", limits)

      status = if path == :resume, do: 200, else: 201
      assert %{"data" => _} = request(ctx, params) |> json_response(status)
    end
  end

  test "a foreign agent remains hidden before limit validation", ctx do
    foreign = insert_agent(user_id: insert_active_user().id)
    params = %{"agent_id" => foreign.id, "execution_limits" => %{"max_model_turns" => 1}}
    assert %{"error" => "not_found"} = request(ctx, params) |> json_response(404)
    refute_received :worker_started
  end

  defp counts, do: {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
  defp attrs(ctx, :fresh), do: %{"agent_id" => ctx.agent.id, "sandbox_mode" => "ephemeral"}
  defp attrs(ctx, :attach), do: %{"agent_id" => ctx.agent.id, "sandbox_id" => ctx.sandbox.id}
  defp attrs(ctx, :resume), do: %{"agent_id" => ctx.agent.id, "channel_id" => "limits"}
  defp attrs(ctx, :rotate), do: Map.put(attrs(ctx, :resume), "fresh", true)

  defp request(ctx, params) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/conversations", Jason.encode!(params))
  end
end
