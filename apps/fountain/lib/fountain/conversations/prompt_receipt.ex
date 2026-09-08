defmodule Fountain.Conversations.PromptReceipt do
  @moduledoc "A durable prompt identity and one-way claim, retained independently of its transcript."
  use Ecto.Schema
  import Ecto.Changeset

  @states ~w(queued claimed refused)
  def states, do: @states

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "prompt_receipts" do
    field :conversation_id, :binary_id
    field :user_id, :binary_id
    field :turn_id, :binary_id
    field :key_hash, :binary, redact: true
    field :payload_hash, :binary, redact: true
    field :state, :string, default: "queued"
    field :sandbox_id, :binary_id
    field :delivery_deadline_at, :utc_datetime_usec
    field :claimed_at, :utc_datetime_usec
    field :failure_reason, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(receipt, attrs) do
    receipt
    |> cast(attrs, [
      :conversation_id,
      :user_id,
      :turn_id,
      :key_hash,
      :payload_hash,
      :state,
      :sandbox_id,
      :delivery_deadline_at,
      :claimed_at,
      :failure_reason
    ])
    |> validate_required([
      :conversation_id,
      :user_id,
      :turn_id,
      :key_hash,
      :payload_hash,
      :state,
      :delivery_deadline_at
    ])
    |> validate_inclusion(:state, @states)
    |> unique_constraint([:conversation_id, :key_hash])
    |> unique_constraint(:conversation_id, name: :prompt_receipts_one_queued_index)
    |> unique_constraint(:turn_id)
    |> immutable_identity(receipt)
    |> immutable_claim(receipt)
  end

  defp immutable_claim(changeset, %{__meta__: %{state: :loaded}, state: state})
       when state in ["claimed", "refused"] do
    Enum.reduce([:state, :sandbox_id, :claimed_at, :failure_reason], changeset, fn field, acc ->
      if Map.has_key?(acc.changes, field), do: add_error(acc, field, "is immutable"), else: acc
    end)
  end

  defp immutable_claim(changeset, _), do: changeset

  defp immutable_identity(changeset, %{__meta__: %{state: :loaded}}) do
    Enum.reduce(
      [:conversation_id, :user_id, :turn_id, :key_hash, :payload_hash, :delivery_deadline_at],
      changeset,
      fn field, acc ->
        if Map.has_key?(acc.changes, field), do: add_error(acc, field, "is immutable"), else: acc
      end
    )
  end

  defp immutable_identity(changeset, _), do: changeset
end
