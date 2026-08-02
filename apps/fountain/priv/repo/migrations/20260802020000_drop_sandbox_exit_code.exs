defmodule Fountain.Repo.Migrations.DropSandboxExitCode do
  use Ecto.Migration

  # `sandboxes.exit_code` has existed since the table was created, with a
  # changeset cast and no writer anywhere. All 455 production rows are null.
  #
  # It is not a missing feature, it is the wrong home for the data. An exit code
  # belongs to a *command*, and a sandbox runs many over its life — that is
  # `turns.exit_code`, which is written and used. A single code on the sandbox
  # could only ever mean "the last one", which is both ambiguous and already
  # available by looking at the last turn.
  #
  # Dropping it rather than finding something to put in it: a column that is
  # cast, never written and never read invites someone to start writing it,
  # and then to reason about a value that means nothing in particular.
  def up do
    alter table(:sandboxes) do
      remove :exit_code
    end
  end

  def down do
    alter table(:sandboxes) do
      add :exit_code, :integer
    end
  end
end
