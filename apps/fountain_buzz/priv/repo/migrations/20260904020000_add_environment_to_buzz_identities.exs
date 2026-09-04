defmodule Fountain.Repo.Migrations.AddEnvironmentToBuzzIdentities do
  @moduledoc """
  The half of `20260817020000_add_per_launch_environment` that belongs to this
  extension (ADR 0043, #1507).

  That migration is core's and altered `buzz_identities`, which a core-only
  distribution does not have. It now skips the Buzz statements when the table is
  absent, and this one covers the one case that leaves: a database migrated
  core-only first, with the extension installed afterwards.

  **A no-op everywhere else, and checked by hand rather than by
  `add_if_not_exists`.** That helper skips the column but still emits the
  foreign-key constraint, which fails with `duplicate_object` on every database
  that already has it — which is every database that exists today, because the
  core migration added it. So the column's presence is asked directly and the
  whole `alter` is skipped.

  The version is later than everything that shipped before the move, so it runs
  last wherever it runs at all.
  """
  use Ecto.Migration

  def up do
    unless environment_id?() do
      alter table(:buzz_identities) do
        add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
      end
    end

    create_if_not_exists index(:buzz_identities, [:environment_id])
  end

  # Deliberately not the reverse. Dropping the column here would take it away
  # from a bundled database that got it from the core migration, which is not
  # this migration's to remove.
  def down, do: :ok

  defp environment_id? do
    %{rows: [[exists]]} =
      repo().query!("""
      SELECT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_name = 'buzz_identities' AND column_name = 'environment_id'
      )
      """)

    exists
  end
end
