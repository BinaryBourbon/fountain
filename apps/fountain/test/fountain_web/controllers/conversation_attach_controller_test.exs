defmodule FountainWeb.ConversationAttachControllerTest do
  # `sandbox_id` on POST /api/conversations (ADR 0023 gate 3), at the door.
  use FountainWeb.ConnCase, async: true
  use Mimic

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    first = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox, first: first}
  end

  defp create(ctx, body) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> post_json("/api/conversations", Map.merge(%{"agent_id" => ctx.agent.id}, body))
  end

  test "attaches: 201, idle, on the named sandbox", ctx do
    data =
      ctx
      |> create(%{"sandbox_id" => ctx.sandbox.id})
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["sandbox_id"] == ctx.sandbox.id
    assert data["status"] == "idle"
    assert data["sandbox"]["agent_id"] == ctx.agent.id
  end

  test "with a prompt, the first turn goes through the wake path", ctx do
    # A `ready` machine with no server: the prompt probes it and starts a
    # server, exactly as prompting a parked conversation does.
    stub(Fountain.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

    data =
      ctx
      |> create(%{"sandbox_id" => ctx.sandbox.id, "prompt" => "hello"})
      |> json_response(201)
      |> Map.fetch!("data")

    assert data["sandbox_id"] == ctx.sandbox.id
  end

  test "an unknown or foreign sandbox is a 404", ctx do
    foreign = insert_sandbox(user_id: insert_active_user().id, status: "ready")

    for id <- [foreign.id, Ecto.UUID.generate()] do
      assert %{"error" => "sandbox_not_found"} =
               ctx |> create(%{"sandbox_id" => id}) |> json_response(404)
    end
  end

  test "a terminated sandbox is a 409 that names its state", ctx do
    {:ok, _} = Fountain.Conversations.update_sandbox(ctx.sandbox, %{status: "terminated"})

    assert %{"error" => "sandbox_not_attachable", "status" => "terminated"} =
             ctx |> create(%{"sandbox_id" => ctx.sandbox.id}) |> json_response(409)
  end

  test "a different identity is a 422", ctx do
    vault = insert_vault(user_id: ctx.user.id)

    assert %{"error" => "sandbox_identity_mismatch"} =
             ctx
             |> create(%{"sandbox_id" => ctx.sandbox.id, "vault_id" => vault.id})
             |> json_response(422)
  end

  test "a one-at-a-time runtime at capacity is a 409 when a prompt comes with it", ctx do
    agent = ctx.agent |> Ecto.Changeset.change(runtime: "opencode") |> Fountain.Repo.update!()
    {:ok, _} = Fountain.Conversations.update_conversation(ctx.first, %{runtime: "opencode"})

    insert_turn(ctx.first, %{
      status: "running",
      prompt: "busy",
      started_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })

    ctx = %{ctx | agent: agent}

    assert %{"error" => "sandbox_at_capacity"} =
             ctx
             |> create(%{"sandbox_id" => ctx.sandbox.id, "prompt" => "hello"})
             |> json_response(409)

    # Nothing was created by the refusal.
    assert length(Fountain.Conversations.list_conversations(ctx.user.id)) == 1
  end
end
