defmodule Fountain.Repo.Migrations.AddLabelsToConversations do
  use Ecto.Migration

  # #1637: free-form `key => value` strings a program stamps on its own run —
  # `env=prod`, `drift=true` — so the list can slice by them. At most 32
  # entries; the rule lives in `Fountain.Conversations.Labels`.
  #
  # The list filter is jsonb containment (`labels @> '{"env":"prod"}'`), which
  # is what the GIN index serves. `jsonb_path_ops` rather than the default
  # operator class: containment is the only operator the filter ever uses, and
  # that class indexes whole paths instead of every key and value separately,
  # so it is smaller and faster for exactly this query.
  def change do
    alter table(:conversations) do
      add :labels, :map, null: false, default: %{}
    end

    create index(:conversations, ["labels jsonb_path_ops"],
             using: :gin,
             name: :conversations_labels_gin_index
           )
  end
end
