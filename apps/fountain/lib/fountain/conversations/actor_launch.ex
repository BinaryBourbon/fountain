defmodule Fountain.Conversations.ActorLaunch do
  @moduledoc "An explicit fresh-machine launch, acknowledged atomically by its first actor claim."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "actor_launches" do
    field :user_id, :binary_id
    field :conversation_id, :binary_id
    field :sandbox_id, :binary_id
    field :runtime, :string
    field :opening_receipt_id, :binary_id
    field :deadline_at, :utc_datetime_usec
    field :state, :string, default: "requested"
    field :actor_claim_id, :binary_id
    field :acknowledged_at, :utc_datetime_usec
    field :refused_at, :utc_datetime_usec
    field :failure_reason, :string
    timestamps(type: :utc_datetime_usec)
  end
end
