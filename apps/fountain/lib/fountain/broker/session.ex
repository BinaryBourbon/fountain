defmodule Fountain.Broker.Session do
  @moduledoc """
  One proxy session: the token a sandbox dials the broker with, bound to the
  conversation whose credentials the proxy attaches. See `Fountain.Broker.Sessions`.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "broker_sessions" do
    field :token_hash, :binary
    field :vault, :string
    field :conversation_id, :binary_id
    field :user_id, :binary_id
    field :credentials_ciphertext, :binary
    field :services, {:array, :map}, default: []
    field :unmatched_host_policy, :string, default: "passthrough"
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :vault,
      :conversation_id,
      :user_id,
      :credentials_ciphertext,
      :services,
      :unmatched_host_policy,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :vault,
      :conversation_id,
      :user_id,
      :credentials_ciphertext,
      :expires_at
    ])
    |> validate_inclusion(:unmatched_host_policy, ["passthrough", "deny"])
    |> unique_constraint(:token_hash)
  end
end
