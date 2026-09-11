defmodule Fountain.Repo.Migrations.BoundLegacyPrincipalKeyExpiry do
  use Ecto.Migration

  def up do
    # An older process can still mint a NULL expiry during a rolling deploy.
    # Give those writes the same deadline as the new issuer, without changing
    # explicit grant deadlines or the lifetime of full/sprite credentials.
    execute """
    CREATE FUNCTION fountain_bound_principal_key_expiry() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NEW.expires_at IS NULL AND 'principal' = ANY(NEW.scopes) THEN
        NEW.expires_at := date_trunc('second', CURRENT_TIMESTAMP AT TIME ZONE 'UTC')
                          + INTERVAL '30 days';
      END IF;
      RETURN NEW;
    END;
    $$
    """

    execute """
    CREATE TRIGGER bound_principal_key_expiry
    BEFORE INSERT OR UPDATE OF scopes, expires_at ON api_keys
    FOR EACH ROW EXECUTE FUNCTION fountain_bound_principal_key_expiry()
    """

    # Existing active keys get a full renewal window from migration time,
    # rather than expiring immediately because they were minted long ago.
    execute """
    UPDATE api_keys
    SET expires_at = date_trunc('second', CURRENT_TIMESTAMP AT TIME ZONE 'UTC')
                     + INTERVAL '30 days'
    WHERE expires_at IS NULL AND revoked_at IS NULL AND 'principal' = ANY(scopes)
    """
  end

  def down do
    execute "DROP TRIGGER bound_principal_key_expiry ON api_keys"
    execute "DROP FUNCTION fountain_bound_principal_key_expiry()"
    # Retain assigned deadlines: clearing them would also immortalize keys
    # deliberately issued with the same expiry after this migration.
  end
end
