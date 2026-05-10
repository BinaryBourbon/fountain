defmodule Fountain.Repo.Migrations.BackfillConversationAndSandboxUserIds do
  use Ecto.Migration

  def up do
    # Conversations were created without user_id propagation; agent.user_id
    # is the source of truth for who owns the conversation.
    execute("""
    UPDATE conversations c
       SET user_id = a.user_id
      FROM agents a
     WHERE c.agent_id = a.id
       AND c.user_id IS NULL
       AND a.user_id IS NOT NULL
    """)

    # Sandboxes have the same gap. Derive ownership from the conversations
    # attached to them; pick any (they should all share an owner once the
    # conversation backfill above runs).
    execute("""
    UPDATE sandboxes s
       SET user_id = c.user_id
      FROM conversations c
     WHERE c.sandbox_id = s.id
       AND s.user_id IS NULL
       AND c.user_id IS NOT NULL
    """)

    # Anything still NULL has no agent or no conversations — orphan rows.
    # Delete them rather than carry around unreachable data.
    execute("DELETE FROM conversations WHERE user_id IS NULL")
    execute("DELETE FROM sandboxes WHERE user_id IS NULL")
  end

  def down, do: :ok
end
