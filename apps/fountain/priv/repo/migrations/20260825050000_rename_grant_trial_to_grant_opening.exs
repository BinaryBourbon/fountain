defmodule Fountain.Repo.Migrations.RenameGrantTrialToGrantOpening do
  use Ecto.Migration

  # ADR 0031: the opening credit is not a trial. The ledger reason, the
  # idempotency key and the resource type all said "trial"; rename the rows
  # written before the vocabulary changed so one word means one thing.
  def up do
    execute """
    UPDATE credit_ledger
    SET reason = 'grant_opening',
        idempotency_key = replace(idempotency_key, 'grant_trial:', 'grant_opening:'),
        resource_type = CASE WHEN resource_type = 'trial' THEN 'opening' ELSE resource_type END
    WHERE reason = 'grant_trial'
    """
  end

  def down do
    execute """
    UPDATE credit_ledger
    SET reason = 'grant_trial',
        idempotency_key = replace(idempotency_key, 'grant_opening:', 'grant_trial:'),
        resource_type = CASE WHEN resource_type = 'opening' THEN 'trial' ELSE resource_type END
    WHERE reason = 'grant_opening'
    """
  end
end
