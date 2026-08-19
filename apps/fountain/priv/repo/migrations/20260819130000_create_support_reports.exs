defmodule Fountain.Repo.Migrations.CreateSupportReports do
  use Ecto.Migration

  def change do
    create table(:support_reports, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :nilify_all)
      add :category, :string, null: false
      add :message, :text, null: false
      # what the client knew when the report was filed: conversation, agent,
      # sandbox, presence, last events, app version, URL — never secrets
      add :context, :map, null: false, default: %{}
      add :client, :string
      add :screenshot, :binary
      add :screenshot_media_type, :string
      add :status, :string, null: false, default: "new"
      add :forwarded_at, :utc_datetime
      add :external_url, :string
      add :forward_error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:support_reports, [:user_id])
    create index(:support_reports, [:status, :inserted_at])
  end
end
