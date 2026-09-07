defmodule Fountain.Conversations.TurnExecution do
  @moduledoc """
  A bounded turn's immutable remote binding and termination journal.

  The connection can span several turns; each turn has its own absolute
  deadline and completion decision. Uncertain provider writes retain this
  record and its conversation fence. Only ExecutionGuard mutates it.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @states ~w(active awaiting_identity ready submitted uncertain stopped completed)

  schema "turn_executions" do
    field :turn_id, :binary_id
    field :conversation_id, :binary_id
    field :user_id, :binary_id
    field :sandbox_id, :binary_id
    field :sandbox_name, :string
    field :provider, :string
    field :connection_id, :binary_id
    field :provider_session_id, :string
    field :deadline_at, :utc_datetime_usec
    field :state, :string, default: "active"
    field :spawn_submitted_at, :utc_datetime_usec
    field :attempt_id, :binary_id
    field :submitted_at, :utc_datetime_usec
    field :confirmed_at, :utc_datetime_usec
    field :last_error, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(execution, attrs) do
    execution
    |> cast(attrs, [
      :turn_id,
      :conversation_id,
      :user_id,
      :sandbox_id,
      :sandbox_name,
      :provider,
      :connection_id,
      :provider_session_id,
      :deadline_at,
      :state,
      :spawn_submitted_at,
      :attempt_id,
      :submitted_at,
      :confirmed_at,
      :last_error
    ])
    |> validate_required([
      :turn_id,
      :conversation_id,
      :user_id,
      :sandbox_id,
      :sandbox_name,
      :provider,
      :connection_id,
      :deadline_at,
      :state
    ])
    |> validate_inclusion(:state, @states)
    |> immutable_binding()
    |> unique_constraint(:turn_id)
    |> unique_constraint(:conversation_id, name: :turn_executions_open_conversation_index)
  end

  defp immutable_binding(%{data: %{__meta__: %{state: :loaded}}} = changeset) do
    fields = [
      :turn_id,
      :conversation_id,
      :user_id,
      :sandbox_id,
      :sandbox_name,
      :provider,
      :connection_id,
      :deadline_at
    ]

    fields =
      if changeset.data.provider_session_id, do: [:provider_session_id | fields], else: fields

    fields =
      if changeset.data.spawn_submitted_at, do: [:spawn_submitted_at | fields], else: fields

    fields = if changeset.data.attempt_id, do: [:attempt_id | fields], else: fields

    Enum.reduce(fields, changeset, fn field, acc ->
      if Map.has_key?(acc.changes, field), do: add_error(acc, field, "is immutable"), else: acc
    end)
  end

  defp immutable_binding(changeset), do: changeset
end
