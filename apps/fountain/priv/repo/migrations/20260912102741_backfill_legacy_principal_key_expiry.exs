defmodule Fountain.Repo.Migrations.BackfillLegacyPrincipalKeyExpiry do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    # The trigger committed in the preceding migration already bounds new
    # writes. This scan holds only the UPDATE's ROW EXCLUSIVE table lock, so
    # unrelated writes and authentication reads can continue. Fail and retry
    # if contention or the scan exceeds the budgets; a failed run rolls back
    # completely and leaves this migration pending.
    #
    # Existing active keys get a full renewal window from this statement,
    # rather than expiring immediately because they were minted long ago.
    execute """
    UPDATE api_keys
    SET expires_at = date_trunc('second', statement_timestamp() AT TIME ZONE 'UTC')
                     + INTERVAL '30 days'
    WHERE expires_at IS NULL AND revoked_at IS NULL AND 'principal' = ANY(scopes)
    """
  end

  def down do
    # Retain assigned deadlines: clearing them would also immortalize keys
    # deliberately issued with the same expiry after this migration.
    :ok
  end
end
