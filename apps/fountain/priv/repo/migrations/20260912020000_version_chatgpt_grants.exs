defmodule Fountain.Repo.Migrations.VersionChatgptGrants do
  use Ecto.Migration

  def up do
    # No released writer creates tenant grants yet. Their encryption cannot
    # safely be inferred from an owner column added for future use.
    execute("""
    DO $$ BEGIN
      IF EXISTS (SELECT 1 FROM platform_chatgpt_account WHERE user_id IS NOT NULL) THEN
        RAISE EXCEPTION 'Unexpected tenant ChatGPT grants: inspect ownership and encryption before migrating';
      END IF;
    END $$;
    """)

    alter table(:platform_chatgpt_account) do
      add :generation, :uuid, null: false, default: fragment("gen_random_uuid()")
      add :lock_version, :bigint, null: false, default: 1
    end

    create constraint(:platform_chatgpt_account, :chatgpt_grant_positive_version,
             check: "lock_version > 0"
           )
  end

  def down do
    drop constraint(:platform_chatgpt_account, :chatgpt_grant_positive_version)

    alter table(:platform_chatgpt_account) do
      remove :lock_version
      remove :generation
    end
  end
end
