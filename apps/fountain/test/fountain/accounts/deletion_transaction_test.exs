defmodule Fountain.Accounts.DeletionTransactionTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.Conversations.ConversationServer

  for operation <- [:delete_user, :destroy_user_sprites, :destroy_id_sprites] do
    test "#{operation} refuses an enclosing transaction before teardown" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
      events = Fountain.Audit.list_for_user(user.id)

      stub(ConversationServer, :whereis, fn _ -> self() end)
      reject(ConversationServer, :terminate_conversation, 2)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 case unquote(operation) do
                   :delete_user -> Deletion.delete_user(user)
                   :destroy_user_sprites -> Deletion.destroy_sprites(user)
                   :destroy_id_sprites -> Deletion.destroy_sprites(user.id)
                 end
               end)

      assert Repo.get(User, user.id)
      assert Repo.reload!(agent)
      assert Repo.reload!(sandbox).status == "ready"
      assert Repo.reload!(conv).status == "idle"
      assert Fountain.Audit.list_for_user(user.id) == events
    end
  end
end
