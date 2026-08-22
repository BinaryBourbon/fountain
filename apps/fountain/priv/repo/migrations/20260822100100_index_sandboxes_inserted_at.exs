defmodule Fountain.Repo.Migrations.IndexSandboxesInsertedAt do
  use Ecto.Migration

  # Spend attribution asks "which sandboxes overlapped this period", which is
  # a range scan on `inserted_at`. `sandboxes` is never pruned — it is the
  # durable record of what the platform paid a provider for — so the scan
  # grows with the lifetime of the instance while a month's answer does not.
  def change do
    create index(:sandboxes, [:inserted_at])
  end
end
