defmodule Fountain.Repo.Migrations.CreatePromptReceipts do
  use Ecto.Migration

  def change do
    # Retain the idempotency tombstone if transcript retention removes the turn.
    # No prompt, image bytes or raw idempotency key is duplicated here.
    create table(:prompt_receipts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :conversation_id, :binary_id, null: false
      add :user_id, :binary_id, null: false
      add :turn_id, :binary_id, null: false
      add :key_hash, :binary, null: false
      add :payload_hash, :binary, null: false
      add :state, :text, null: false, default: "queued"
      add :sandbox_id, :binary_id
      add :claimed_at, :utc_datetime_usec
      add :failure_reason, :text
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:prompt_receipts, [:conversation_id, :key_hash])
    create unique_index(:prompt_receipts, [:turn_id])

    create unique_index(:prompt_receipts, [:conversation_id],
             where: "state = 'queued'",
             name: :prompt_receipts_one_queued_index
           )

    create constraint(:prompt_receipts, :prompt_receipts_state_check,
             check: "state IN ('queued', 'claimed', 'refused')"
           )

    create constraint(:prompt_receipts, :prompt_receipts_hash_check,
             check: "octet_length(key_hash) = 32 AND octet_length(payload_hash) = 32"
           )

    create constraint(:prompt_receipts, :prompt_receipts_claim_check,
             check:
               "(state = 'claimed' AND sandbox_id IS NOT NULL AND claimed_at IS NOT NULL) OR " <>
                 "(state != 'claimed' AND sandbox_id IS NULL AND claimed_at IS NULL)"
           )

    create constraint(:prompt_receipts, :prompt_receipts_refusal_check,
             check: "(state = 'refused') = (failure_reason IS NOT NULL)"
           )
  end
end
