defmodule Fountain.Conversations.ConversationServerBuildFingerprintTest do
  # What the disk was built from is recorded on the row when the machine
  # reaches `ready` (#1565). Without it a later reapply has to guess whether a
  # selection needs the disk built again, and an environment edited after the
  # build reads as "unchanged".
  use Fountain.ConversationServerCase

  alias Fountain.Conversations
  alias Fountain.Conversations.Reapply

  test "a ready machine records the environment digest and the skills mounted on it" do
    stub_happy_sprite()

    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "echo hello")
    skills = [%{"name" => "mine", "content" => "# m"}]

    agent =
      insert_agent(user_id: user.id, runtime: "gemini", environment_id: env.id, skills: skills)

    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, _ref, :alive} = start_server(conv)

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.status == "ready"
    assert sandbox.build_fingerprint == Reapply.fingerprint(env)
    assert sandbox.applied_skills == skills

    GenServer.call(pid, :terminate_conv, 30_000)
  end

  test "a machine built with no environment records the digest that stands for none" do
    stub_happy_sprite()

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, _ref, :alive} = start_server(conv)

    sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
    assert sandbox.build_fingerprint == Reapply.fingerprint(nil)
    assert sandbox.applied_skills == []

    GenServer.call(pid, :terminate_conv, 30_000)
  end
end
