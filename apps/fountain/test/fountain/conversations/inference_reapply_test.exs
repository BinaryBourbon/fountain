defmodule Fountain.Conversations.InferenceReapplyTest do
  use Fountain.DataCase, async: true
  alias Fountain.{Conversations, Crypto, InferenceCredentials}
  alias Fountain.Conversations.{InferenceBinding, Reapply, SpriteEnv, TurnMachine}
  alias Fountain.InferenceCredentials.Source

  setup do
    user = insert_verified_user()
    {:ok, dek} = Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "same-key")
    env = insert_env(user_id: user.id)

    other =
      insert_env(
        user_id: user.id,
        packages: env.packages,
        repositories: env.repositories,
        setup_script: env.setup_script,
        env_vars: %{"WHO" => "new-environment"}
      )

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        model: "anthropic/claude-opus-5",
        environment_id: env.id
      )

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        mode: "ephemeral",
        agent_id: agent.id,
        environment_id: env.id,
        build_fingerprint: Reapply.fingerprint(env)
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    {:ok, source, _} =
      InferenceCredentials.resolve(user.id, agent.model, agent.runtime, environment_id: env.id)

    assert :ok = InferenceBinding.reserve(conv, source)

    %{
      user: user,
      agent: agent,
      env: env,
      other: other,
      sandbox: sandbox,
      conv: Repo.reload!(conv),
      source: source
    }
  end

  test "environment reapply retains the credential and admits a turn with the new context", c do
    historical = insert_turn(c.conv, status: "completed", inference_source: Source.dump(c.source))

    assert {:ok, reapplied} =
             Conversations.reapply_conversation(c.conv, %{"environment_id" => c.other.id})

    assert reapplied.environment_id == c.other.id

    assert {:ok, _, source, %{anthropic_api_key: "same-key"}} =
             SpriteEnv.resolve_inference(reapplied, c.agent, c.other, nil)

    assert source.identity == c.source.identity
    assert source.revision == c.source.revision
    assert source.environment_id == c.other.id

    assert {:ok, _, turn} =
             TurnMachine.open(
               reapplied.id,
               c.sandbox.id,
               "next",
               c.agent,
               reapplied.configuration_revision,
               source
             )

    assert turn.inference_source == Source.dump(source)
    assert Repo.reload!(historical).inference_source == Source.dump(c.source)
  end

  test "an explicit model reapply refreshes context without silently switching credentials", c do
    {:ok, agent} = Fountain.Agents.update_agent(c.agent, %{model: "anthropic/claude-sonnet-5"})
    assert {:ok, reapplied} = Conversations.reapply_conversation(c.conv)
    assert {:ok, _, source, _} = SpriteEnv.resolve_inference(reapplied, agent, c.env, nil)
    assert source.model == agent.model
    assert source.identity == c.source.identity
    assert source.revision == c.source.revision
  end

  test "an incompatible override is refused before configuration or machine identity changes",
       c do
    {:ok, other} =
      Fountain.Environments.update_environment(
        c.other,
        %{env_vars: %{"ANTHROPIC_API_KEY" => "different-key"}}
      )

    before = Repo.reload!(c.conv)
    machine = Repo.reload!(c.sandbox)

    assert {:error, :inference_source_changed} =
             Conversations.reapply_conversation(c.conv, %{"environment_id" => other.id})

    assert Repo.reload!(c.conv) == before
    assert Repo.reload!(c.sandbox) == machine
  end
end
