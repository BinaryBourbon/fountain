defmodule Fountain.Repo.Migrations.CreateInferenceCredentials do
  use Ecto.Migration

  def change do
    create table(:inference_credentials, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false

      # Each ciphertext is encrypted with the user's per-tenant DEK.
      # Nullable: a user may have set zero, one, or many providers.
      add :anthropic_api_key_ciphertext, :binary
      add :claude_code_oauth_token_ciphertext, :binary
      add :openai_api_key_ciphertext, :binary
      add :gemini_api_key_ciphertext, :binary

      timestamps(type: :utc_datetime)
    end

    create unique_index(:inference_credentials, [:user_id])
  end
end
