defmodule Fountain.Repo.Migrations.CreatePlatformInferenceKeys do
  use Ecto.Migration

  # The deployment's own inference keys, set from `/admin/inference` (ADR 0038
  # decision 3, amended). One row per provider; the value is encrypted under
  # the master key (`Fountain.Crypto.encrypt_platform/1`), never stored plain.
  # A row here wins over the `PLATFORM_<PROVIDER>_API_KEY` variable, which
  # stays as the seed for a deployment configured from its environment.
  #
  # `updated_by_user_id` is who set it, for the admin page; it is nilified
  # rather than cascaded so deleting an operator's account does not delete
  # the deployment's key.
  def change do
    create table(:platform_inference_keys, primary_key: false) do
      add :provider, :string, primary_key: true
      add :ciphertext, :binary, null: false

      add :updated_by_user_id, references(:users, type: :binary_id, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end
  end
end
