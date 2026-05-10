defmodule Fountain.Billing.UsageEvent do
  @moduledoc """
  Schema for the `usage_events` table.

  Tracks platform usage for billing aggregation and post-hoc analytics.
  Written synchronously from `ConversationServer` at key lifecycle points;
  never updated after insertion (no `updated_at`).
  """

  use Ecto.Schema
  import Ecto.Changeset

  # The migration uses the default integer (bigint) PK — better for append-only
  # ordered reads than UUID.
  @primary_key {:id, :id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "usage_events" do
    field :user_id, :binary_id
    field :event_type, :string
    field :resource_id, :binary_id
    field :resource_type, :string
    field :metadata, :map, default: %{}
    # Write-once timestamp managed manually (no `timestamps()` macro).
    field :inserted_at, :utc_datetime
  end

  @valid_event_types ~w(sandbox_provisioned turn_started sandbox_terminated)

  def changeset(usage_event, attrs) do
    usage_event
    |> cast(attrs, [:user_id, :event_type, :resource_id, :resource_type, :metadata, :inserted_at])
    |> validate_required([:user_id, :event_type, :inserted_at])
    |> validate_inclusion(:event_type, @valid_event_types)
  end
end
