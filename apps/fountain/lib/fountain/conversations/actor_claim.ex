defmodule Fountain.Conversations.ActorClaim do
  @moduledoc "One immutable actor incarnation and its original tenant/machine binding."
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: false}
  schema "conversation_actor_claims" do
    field :user_id, :binary_id
    field :conversation_id, :binary_id
    field :sandbox_id, :binary_id
    field :launch_id, :binary_id
    field :state, :string, default: "active"
    timestamps(type: :utc_datetime_usec)
  end
end
