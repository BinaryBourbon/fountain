defmodule Fountain.Conversations.ActorStartup do
  @moduledoc "One reconnect attempt's immutable deadline and local startup outcome."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "actor_startups" do
    field :actor_claim_id, :binary_id
    field :user_id, :binary_id
    field :conversation_id, :binary_id
    field :sandbox_id, :binary_id
    field :deadline_at, :utc_datetime_usec
    field :state, :string, default: "starting"
    field :settled_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
