defmodule Fountain.Conversations.SandboxOperation do
  @moduledoc "Durable provider intent and retained ownership; never transcript data."
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "sandbox_operations" do
    field :sandbox_id, :binary_id
    field :conversation_id, :binary_id
    field :user_id, :binary_id
    field :provider, :string
    field :sandbox_name, :string
    field :provider_instance_id, :string
    field :creation_id, :binary_id
    field :action, :string
    field :state, :string
    field :holds_slot, :boolean, default: false
    field :sandbox_started_at, :utc_datetime
    field :submitted_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :recovery_checked_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [
      :sandbox_id,
      :conversation_id,
      :user_id,
      :provider,
      :sandbox_name,
      :provider_instance_id,
      :creation_id,
      :action,
      :state,
      :holds_slot,
      :sandbox_started_at,
      :submitted_at,
      :confirmed_at,
      :recovery_checked_at
    ])
    |> validate_required([:sandbox_id, :user_id, :provider, :sandbox_name, :action, :state])
    |> validate_inclusion(:action, ~w(create destroy park resume))
    |> validate_inclusion(:state, ~w(submitted uncertain confirmed refused))
    |> unique_constraint(:sandbox_name, name: :sandbox_operations_physical_name_index)
    |> unique_constraint(:sandbox_id, name: :sandbox_operations_creation_index)
    |> unique_constraint(:sandbox_id, name: :sandbox_operations_pending_index)
    |> unique_constraint(:provider_instance_id, name: :sandbox_operations_provider_instance_index)
    |> immutable_binding()
  end

  defp immutable_binding(%{data: %{__meta__: %{state: :loaded}}} = changeset) do
    fields =
      ~w(sandbox_id conversation_id user_id provider sandbox_name creation_id action submitted_at sandbox_started_at)a

    fields =
      if changeset.data.provider_instance_id, do: [:provider_instance_id | fields], else: fields

    Enum.reduce(fields, changeset, fn field, acc ->
      if Map.has_key?(acc.changes, field), do: add_error(acc, field, "is immutable"), else: acc
    end)
  end

  defp immutable_binding(changeset), do: changeset
end
