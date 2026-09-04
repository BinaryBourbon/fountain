defmodule Fountain.Principals.Owner do
  @moduledoc """
  Which registered account owns a principal (ADR 0044).

  This is the whole of what a claim writes. Nothing about the principal's
  resources moves, because the principal is the `users` row those resources
  are already scoped to; the claim only records who is now behind it.

  One owner per principal — `unique_index(:principal_user_id)` — which is the
  backstop behind the row lock the claim takes. An owner may hold many.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}
  schema "principal_owners" do
    belongs_to :owner_user, Fountain.Accounts.User
    belongs_to :principal_user, Fountain.Accounts.User

    timestamps(type: :utc_datetime)
  end

  def changeset(owner, attrs) do
    owner
    |> cast(attrs, [:owner_user_id, :principal_user_id])
    |> validate_required([:owner_user_id, :principal_user_id])
    |> unique_constraint(:principal_user_id)
    |> foreign_key_constraint(:owner_user_id)
    |> foreign_key_constraint(:principal_user_id)
  end
end
