defmodule Fountain.Exports.Export do
  @moduledoc """
  One requested account-data export.

  `payload` is the gzipped JSON document, present once `status` is
  `"completed"`. `byte_size` is the size of the raw JSON before compression,
  kept for display. `expires_at` bounds how long the artifact is downloadable;
  after that the row is purged.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending completed failed)

  @type t :: %__MODULE__{}

  schema "account_exports" do
    field :status, :string, default: "pending"
    field :payload, :binary
    field :byte_size, :integer
    field :error, :string
    field :expires_at, :utc_datetime
    belongs_to :user, User
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(export, attrs) do
    export
    |> cast(attrs, [:status, :payload, :byte_size, :error, :expires_at, :user_id])
    |> validate_required([:status, :user_id])
    |> validate_inclusion(:status, @statuses)
  end
end
