defmodule Fountain.Repo.Migrations.AddRespondToToBuzzIdentities do
  @moduledoc """
  The inbound author gate a hosted `buzz-acp` runs with (#790): who may
  @-mention the agent and fire a turn. `respond_to` is one of buzz-acp's
  `--respond-to` modes (`owner-only`, `allowlist`, `anyone`, `nobody`) and
  `respond_to_allowlist` the 64-hex pubkeys admitted in `allowlist` mode. The
  desktop already sends both on every provider deploy; until now the hosted
  harness silently ran at the `owner-only` default whatever the record said.
  """
  use Ecto.Migration

  def change do
    alter table(:buzz_identities) do
      add :respond_to, :string, null: false, default: "owner-only"
      add :respond_to_allowlist, {:array, :string}, null: false, default: []
    end
  end
end
