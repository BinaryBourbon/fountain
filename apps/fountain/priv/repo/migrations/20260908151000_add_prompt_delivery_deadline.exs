defmodule Fountain.Repo.Migrations.AddPromptDeliveryDeadline do
  use Ecto.Migration

  def up do
    alter table(:prompt_receipts) do
      add :delivery_deadline_at, :utc_datetime_usec
    end

    execute "UPDATE prompt_receipts SET delivery_deadline_at = inserted_at + interval '35 minutes'"

    alter table(:prompt_receipts) do
      modify :delivery_deadline_at, :utc_datetime_usec, null: false
    end
  end

  def down do
    alter table(:prompt_receipts) do
      remove :delivery_deadline_at
    end
  end
end
