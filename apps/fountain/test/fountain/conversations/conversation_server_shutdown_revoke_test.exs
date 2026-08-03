defmodule Fountain.Conversations.ConversationServerShutdownRevokeTest do
  # #322: terminate/2 revokes the sprite's callback API key, but without
  # trap_exit a supervisor shutdown (every deploy, every Horde rebalance)
  # skips terminate/2 entirely — leaving a live sprite-scoped tenant
  # credential outstanding for up to 30 days if the conversation is never
  # resumed. init/1 now traps exits so shutdown runs terminate/2.
  use Fountain.ConversationServerCase

  alias Fountain.Accounts.ApiKey

  defp start_provisioned_server do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent_id: agent.id)

    {pid, ref, :alive} = start_server(conv)
    conv = Conversations._unsafe_get_conversation!(conv.id)
    assert is_binary(conv.callback_api_key_id), "provision should have minted a callback key"
    {pid, ref, conv}
  end

  defp key_revoked?(key_id) do
    %ApiKey{revoked_at: revoked_at} = Repo.get!(ApiKey, key_id)
    revoked_at != nil
  end

  test "a supervisor-style :shutdown exit revokes the callback key" do
    {pid, ref, conv} = start_provisioned_server()
    refute key_revoked?(conv.callback_api_key_id)

    # The exact signal a supervisor sends at teardown. Without trap_exit
    # this killed the process with no terminate/2 — verified against the
    # old code: this test fails there with the key still live.
    Process.exit(pid, :shutdown)
    assert_stopped(ref)

    assert key_revoked?(conv.callback_api_key_id)
  end

  test "a linked crash still takes the server down and revokes on the way" do
    {pid, ref, conv} = start_provisioned_server()

    Process.exit(pid, :some_linked_crash)
    reason = assert_stopped(ref)
    assert reason == :some_linked_crash

    assert key_revoked?(conv.callback_api_key_id)
  end
end
