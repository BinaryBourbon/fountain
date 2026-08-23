defmodule Fountain.Repo.Migrations.CreateSandboxRequests do
  use Ecto.Migration

  @moduledoc """
  The bounded sandbox queue (#1033, ADR 0030): a request that hits the
  per-tenant concurrency cap can wait for a free slot instead of being
  refused, when the caller opts in.

  A queued request is deliberately its own row, not a conversation status: a
  queued start has no sandbox at all, and a `queued` conversation status
  would leak into every list view, the SSE stream and the SDK's enum. The
  conversation (or the scheduled run) comes into existence only when the
  drainer wins a slot.

  Two kinds: `start` carries the original create attrs; `schedule_run`
  carries the schedule id and re-fires `run_schedule` on drain. `attrs` is
  JSON-safe by construction — images are refused at enqueue, and secrets
  never appear in create attrs (vault/environment are referenced by id).
  """

  def change do
    create table(:sandbox_requests, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      add :agent_id, references(:agents, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false, default: "start"
      add :attrs, :map, null: false, default: %{}
      add :schedule_id, :binary_id
      add :source, :string
      add :status, :string, null: false, default: "queued"

      add :conversation_id,
          references(:conversations, type: :binary_id, on_delete: :nilify_all)

      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    # The drainer's read: oldest queued first, per tenant.
    create index(:sandbox_requests, [:user_id, :status, :inserted_at])
    # The backstop sweep's read: every tenant with something queued.
    create index(:sandbox_requests, [:status], where: "status = 'queued'")
  end
end
