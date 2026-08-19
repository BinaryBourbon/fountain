defmodule Fountain.Runners.Runner do
  @moduledoc """
  A machine the user owns that runs the `fountain runner` daemon and serves
  sandboxes for them (ADR 0022).

  The row is identity and telemetry, not a credential: the daemon
  authenticates every connection with an ordinary API key, and the row is
  upserted by `(user_id, name)` when it connects. `connected_at` /
  `last_seen_at` are what the daemon last reported; whether the runner is
  *online right now* is a registry question (`Fountain.Runners.online?/1`),
  never a column.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @name_format ~r/^[a-z0-9][a-z0-9._-]{0,62}$/

  @type t :: %__MODULE__{}

  schema "runners" do
    field :name, :string
    field :hostname, :string
    field :os, :string
    field :arch, :string
    field :version, :string
    field :root, :string
    field :connected_at, :utc_datetime
    field :last_seen_at, :utc_datetime
    belongs_to :user, Fountain.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def changeset(runner, attrs) do
    runner
    |> cast(attrs, [
      :name,
      :hostname,
      :os,
      :arch,
      :version,
      :root,
      :connected_at,
      :last_seen_at,
      :user_id
    ])
    |> validate_required([:name, :user_id])
    |> validate_format(:name, @name_format,
      message: "must be lowercase letters, digits, dots, dashes or underscores (max 63)"
    )
    |> validate_length(:hostname, max: 255)
    |> validate_length(:os, max: 40)
    |> validate_length(:arch, max: 40)
    |> validate_length(:version, max: 80)
    |> validate_length(:root, max: 1024)
    |> unique_constraint([:user_id, :name])
  end
end
