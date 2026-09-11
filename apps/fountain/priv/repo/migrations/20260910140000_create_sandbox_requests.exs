defmodule Fountain.Repo.Migrations.CreateSandboxRequests do
  use Ecto.Migration

  def change do
    create table(:sandbox_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "start"
      add :attrs, :map, null: false, default: %{}
      # Deliberately not a `references/2`, both of them. A schedule or an API
      # key that goes away must leave the id dangling rather than be nilified:
      # a dangling `schedule_id` replays as `:schedule_deleted` (terminal), and
      # a dangling `sandbox_key_id` fails the ownership comparison in
      # `Conversations.set_conversation_labels/4`. Nilifying either would turn a
      # refusal into a permission the original request never had.
      add :schedule_id, :binary_id
      add :sandbox_key_id, :binary_id
      add :source, :string
      add :status, :string, null: false, default: "queued"

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    # The FIFO read, the depth count and the position count are all
    # "this tenant, these statuses, in insertion order".
    create index(:sandbox_requests, [:user_id, :status, :inserted_at])

    # The fan-out probe asks "does any tenant have live work" before it
    # schedules anything, and the answer is no on almost every sandbox status
    # change. Partial, so the index stays the size of the live queue rather
    # than of its history.
    create index(:sandbox_requests, [:status], where: "status IN ('queued', 'starting')")
  end
end
