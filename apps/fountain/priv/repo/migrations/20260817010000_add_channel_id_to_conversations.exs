defmodule Fountain.Repo.Migrations.AddChannelIdToConversations do
  use Ecto.Migration

  # An opaque, client-supplied key naming the external channel a conversation
  # is bound to — a Buzz channel id from `_meta.channelId` on ACP `session/new`
  # (#774). `POST /api/conversations` with a `channel_id` resumes the latest
  # live conversation for the same user + agent + vault + channel instead of
  # opening a new one, so a client that forgets its sessions (a restarted
  # buzz-acp) lands back on the same conversation and sandbox.
  def change do
    alter table(:conversations) do
      add :channel_id, :string
    end

    create index(:conversations, [:user_id, :agent_id, :channel_id],
             where: "channel_id IS NOT NULL"
           )
  end
end
