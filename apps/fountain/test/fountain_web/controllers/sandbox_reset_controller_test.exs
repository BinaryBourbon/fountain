defmodule FountainWeb.SandboxResetControllerTest do
  # DELETE /api/sandboxes/:id (#1071), at the door.
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    home =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "persistent",
        agent_id: agent.id,
        environment_id: env.id,
        provider: "sprites"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: home, status: "idle")
    stub(Managoat.Sandbox.Sprites, :destroy, fn _h -> :ok end)
    {:ok, user: user, raw_key: raw_key, agent: agent, home: home, conv: conv}
  end

  defp reset(ctx, id) do
    ctx.conn |> authed_with_key(ctx.raw_key) |> delete("/api/sandboxes/#{id}")
  end

  test "204: the home is terminated and the conversation kept", ctx do
    assert ctx |> reset(ctx.home.id) |> response(204)
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "terminated"
    assert Conversations._unsafe_get_conversation!(ctx.conv.id).status == "idle"
  end

  test "404 for another tenant's sandbox, and for a made-up id", ctx do
    other = insert_active_user()
    theirs = insert_sandbox(user_id: other.id, status: "ready", mode: "persistent")

    assert %{"error" => "not_found"} = ctx |> reset(theirs.id) |> json_response(404)
    assert Conversations._unsafe_get_sandbox!(theirs.id).status == "ready"
    assert ctx |> reset(Ecto.UUID.generate()) |> json_response(404)
    assert ctx |> reset("nope") |> json_response(404)
  end

  test "422 sandbox_not_resettable for an ephemeral sandbox", ctx do
    ephemeral = insert_sandbox(user_id: ctx.user.id, status: "ready", mode: "ephemeral")

    assert %{"error" => "sandbox_not_resettable", "reason" => "ephemeral"} =
             ctx |> reset(ephemeral.id) |> json_response(422)
  end

  test "422 sandbox_not_resettable for a home already gone", ctx do
    assert ctx |> reset(ctx.home.id) |> response(204)

    assert %{"error" => "sandbox_not_resettable", "reason" => "terminated"} =
             ctx |> reset(ctx.home.id) |> json_response(422)
  end

  test "409 sandbox_mid_turn while a conversation on it runs a turn", ctx do
    insert_turn(ctx.conv, status: "running")
    assert %{"error" => "sandbox_mid_turn"} = ctx |> reset(ctx.home.id) |> json_response(409)
    assert Conversations._unsafe_get_sandbox!(ctx.home.id).status == "ready"
  end

  test "the reset is audited as api", ctx do
    assert ctx |> reset(ctx.home.id) |> response(204)

    assert [event] =
             Fountain.Audit.list_for_user(ctx.user.id)
             |> Enum.filter(&(&1.action == "sandbox.reset"))

    assert event.actor == "api"
  end
end
