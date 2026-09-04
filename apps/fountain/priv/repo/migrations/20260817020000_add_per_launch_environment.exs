defmodule Fountain.Repo.Migrations.AddPerLaunchEnvironment do
  @moduledoc """
  A conversation's environment becomes a per-launch choice that defaults to
  the agent's (#783): the conversation carries an optional override, a Buzz
  identity can name one for every conversation it opens, and the agent gets an
  allowlist mirroring `allowed_vault_ids` to scope who may override.

  All three are `nilify_all` on environment delete — losing the override falls
  back to the agent's environment; it never orphans a row.

  ## Amended by #1507, and why an applied migration was touched at all

  `buzz_identities` belongs to the Buzz extension now (ADR 0043), and a
  core-only distribution has no such table — this migration would abort on the
  first `mix ecto.migrate` of a fresh core database, which would mean the core
  distribution could not exist.

  The two Buzz statements are therefore conditional on the table being there.
  This changes nothing for any database that has already run this version: they
  are all bundled, the table was present, and an applied migration never runs
  again. On a fresh **bundled** database the extension's own
  `20260816120000_create_buzz_identities` has a lower version and so runs first,
  and these still apply. On a fresh **core** database they are skipped, and
  `20260904020000` in the extension's own path adds the column if the extension
  is ever installed.

  The alternative — deleting the two statements outright — would leave a
  core-then-bundled database without `buzz_identities.environment_id` and no
  migration that adds it.
  """
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:agents) do
      add :allowed_environment_ids, {:array, :binary_id}, null: true
    end

    create index(:conversations, [:environment_id])

    if buzz_identities?() do
      alter table(:buzz_identities) do
        add :environment_id, references(:environments, type: :binary_id, on_delete: :nilify_all)
      end

      create index(:buzz_identities, [:environment_id])
    end
  end

  # `up`/`down` both reach here; on the way down the table's presence is the
  # same question, so one helper serves both directions of `change/0`.
  defp buzz_identities? do
    %{rows: [[exists]]} =
      repo().query!(
        "SELECT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_name = 'buzz_identities')"
      )

    exists
  end
end
