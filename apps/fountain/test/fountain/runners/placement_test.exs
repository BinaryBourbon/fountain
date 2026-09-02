defmodule Fountain.Runners.PlacementTest do
  @moduledoc """
  A conversation on an agent pinned to the runner provider is placed on the
  user's online runner at start — the runner id rides in the sandbox name
  (ADR 0022) — and is refused plainly when no runner is online.
  """

  # `runners_enabled` is global application env (off in test config), so this
  # cannot share a partition with anything reading provider enabledness.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Runners
  alias Managoat.Runner.FakeDaemon

  setup do
    previous = Application.get_env(:fountain, :runners_enabled)
    Application.put_env(:fountain, :runners_enabled, true)
    on_exit(fn -> Application.put_env(:fountain, :runners_enabled, previous) end)
    stub(Horde.DynamicSupervisor, :start_child, fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
    :ok
  end

  test "an agent can pin the runner provider once runners are enabled" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    assert {:ok, agent} = Fountain.Agents.update_agent(agent, %{"sandbox_provider" => "runner"})
    assert agent.sandbox_provider == "runner"
  end

  test "start_conversation refuses when no runner is online, allocating nothing" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    before = Fountain.Quotas.active_sandbox_count(user.id)

    assert {:error, :no_runner_online} =
             Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

    assert Fountain.Quotas.active_sandbox_count(user.id) == before
  end

  test "start_conversation places the sandbox on the online runner" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, sandbox_provider: "runner")
    {:ok, runner} = Runners.register(user.id, %{"name" => "mini"})
    {:ok, daemon} = FakeDaemon.start(runner.id, meta: %{user_id: user.id}, name: "mini")
    on_exit(fn -> FakeDaemon.stop(daemon) end)

    assert {:ok, conv} =
             Conversations.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.provider == "runner"
    assert {:ok, runner_id} = Runners.parse_sandbox_name(sandbox.sprite_name)
    assert runner_id == runner.id
  end

  test "an explicit sprite_name is honored regardless of provider" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    assert {:ok, conv} =
             Conversations.start_conversation(%{
               "agent_id" => agent.id,
               "user_id" => user.id,
               "sprite_name" => "fountain-pinned-name"
             })

    assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).sprite_name ==
             "fountain-pinned-name"
  end
end
