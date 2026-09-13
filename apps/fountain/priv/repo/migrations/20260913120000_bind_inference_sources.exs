defmodule Fountain.Repo.Migrations.BindInferenceSources do
  use Ecto.Migration

  def up do
    alter table(:inference_credentials) do
      add :revision, :uuid, null: false, default: fragment("gen_random_uuid()")
    end

    alter table(:platform_inference_keys) do
      add :revision, :uuid, null: false, default: fragment("gen_random_uuid()")
    end

    for table <- [:environments, :secrets, :vault_secrets] do
      alter table(table) do
        add :inference_revision, :uuid, null: false, default: fragment("gen_random_uuid()")
      end
    end

    alter table(:sandboxes) do
      add :codex_inference_source, :map
    end

    alter table(:conversations) do
      add :inference_source, :map
    end

    alter table(:turns) do
      add :inference_source, :map
    end

    # Take the same tenant lock before every write, including writes made by
    # older serving nodes. Source readers never lock child rows, avoiding the
    # row-lock/advisory-lock inversion PostgreSQL BEFORE triggers can cause.
    execute """
    CREATE FUNCTION fountain_lock_inference_source() RETURNS trigger AS $$
    DECLARE owner_id uuid;
    BEGIN
      IF TG_TABLE_NAME IN ('platform_chatgpt_account', 'platform_inference_keys') THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('inference:platform', 0));
        IF TG_TABLE_NAME = 'platform_inference_keys' AND TG_OP = 'UPDATE' THEN
          IF NEW.ciphertext IS DISTINCT FROM OLD.ciphertext THEN NEW.revision := gen_random_uuid(); END IF;
        END IF;
        IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
      ELSIF TG_TABLE_NAME = 'secrets' THEN
        SELECT user_id INTO owner_id FROM environments WHERE id = COALESCE(NEW.environment_id, OLD.environment_id);
      ELSIF TG_TABLE_NAME = 'vault_secrets' THEN
        SELECT user_id INTO owner_id FROM vaults WHERE id = COALESCE(NEW.vault_id, OLD.vault_id);
      ELSE
        owner_id := COALESCE(NEW.user_id, OLD.user_id);
      END IF;
      PERFORM pg_advisory_xact_lock(hashtextextended('inference:' || owner_id::text, 0));
      IF TG_TABLE_NAME = 'inference_credentials' AND TG_OP = 'UPDATE' THEN
        IF NEW.anthropic_api_key_ciphertext IS DISTINCT FROM OLD.anthropic_api_key_ciphertext OR
           NEW.claude_code_oauth_token_ciphertext IS DISTINCT FROM OLD.claude_code_oauth_token_ciphertext OR
           NEW.openai_api_key_ciphertext IS DISTINCT FROM OLD.openai_api_key_ciphertext OR
           NEW.gemini_api_key_ciphertext IS DISTINCT FROM OLD.gemini_api_key_ciphertext THEN
          NEW.revision := gen_random_uuid();
        END IF;
      END IF;
      IF TG_OP = 'UPDATE' THEN
        IF TG_TABLE_NAME = 'environments' THEN
          IF NEW.env_vars IS DISTINCT FROM OLD.env_vars THEN NEW.inference_revision := gen_random_uuid(); END IF;
        ELSIF TG_TABLE_NAME IN ('secrets', 'vault_secrets') THEN
          IF NEW.value_ciphertext IS DISTINCT FROM OLD.value_ciphertext OR NEW.key IS DISTINCT FROM OLD.key THEN NEW.inference_revision := gen_random_uuid(); END IF;
        END IF;
      END IF;
      IF TG_OP = 'DELETE' THEN RETURN OLD; ELSE RETURN NEW; END IF;
    END;
    $$ LANGUAGE plpgsql
    """

    for table <-
          ~w(inference_credentials environments vaults secrets vault_secrets platform_chatgpt_account platform_inference_keys) do
      execute "CREATE TRIGGER inference_source_lock BEFORE INSERT OR UPDATE OR DELETE ON #{table} FOR EACH ROW EXECUTE FUNCTION fountain_lock_inference_source()"
    end
  end

  def down do
    for table <-
          ~w(inference_credentials environments vaults secrets vault_secrets platform_chatgpt_account platform_inference_keys) do
      execute "DROP TRIGGER inference_source_lock ON #{table}"
    end

    execute "DROP FUNCTION fountain_lock_inference_source()"

    for table <- [:environments, :secrets, :vault_secrets] do
      alter table(table), do: remove(:inference_revision)
    end

    alter table(:turns), do: remove(:inference_source)
    alter table(:conversations), do: remove(:inference_source)
    alter table(:sandboxes), do: remove(:codex_inference_source)
    alter table(:inference_credentials), do: remove(:revision)
    alter table(:platform_inference_keys), do: remove(:revision)
  end
end
