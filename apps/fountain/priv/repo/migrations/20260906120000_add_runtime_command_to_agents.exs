defmodule Fountain.Repo.Migrations.AddRuntimeCommandToAgents do
  use Ecto.Migration

  @moduledoc """
  The command the `acp` runtime launches (#1634).

  Every other runtime resolves its own executable from a pinned table, so the
  column is null for all of them and required for `acp` alone. The value is a
  free string, deliberately: it is resolved inside the sandbox, under the same
  isolation an agent's `setup_script` already runs under, so a catalogue of
  blessed commands would buy nothing and would stop a self-hoster running
  their own program.

  Text rather than a bounded varchar. A command may be a whole shell line
  ("cd /srv/app && bin/agent acp"), and the changeset is where a length rule
  belongs if one is ever wanted.

  `model` loses its NOT NULL in the same migration. It is required for every
  runtime that drives one and meaningless for this one, and that difference
  is a rule about the pair of columns rather than about either alone, so it
  belongs in `Fountain.Agents.Agent.changeset/2` where both are in hand. The
  column stays for every existing row.
  """

  def change do
    alter table(:agents) do
      add :runtime_command, :text
      modify :model, :string, null: true, from: {:string, null: false}
    end
  end
end
