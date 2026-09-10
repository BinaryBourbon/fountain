defmodule Fountain.Conversations.ExecutionAllowance do
  @moduledoc """
  Versioned storage for a conversation's resolved execution allowance.

  This is a storage primitive, not an admission or enforcement API. Use the
  owner-scoped `Conversations.narrow_execution_allowance/3` for existing records.
  Initial admission must establish conversation ownership,
  resolve current ceilings and prove runtime support before saving an allowance.
  Later turns and recovery must consult it before this becomes a usable setting.

  Updates must use `narrow_changeset/2`. A stale revision fails with
  `Ecto.StaleEntryError` (or a changeset error with `stale_error_field: :revision`).
  Reload and revalidate the request after a conflict; never retry the old map as
  a replacement. An opaque revision avoids counter rollover accepting old writes.
  This record does not reset or replace an in-flight turn's deadline or usage.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.{Conversation, ExecutionLimits}

  @primary_key false
  @foreign_key_type :binary_id
  schema "execution_allowances" do
    belongs_to :conversation, Conversation, primary_key: true
    field :limits, :map, default: %{}
    field :revision, :binary_id
    timestamps(type: :utc_datetime_usec)
  end

  @doc "Insert a resolved allowance once; a duplicate cannot replace it."
  def new_changeset(conversation_id, limits) do
    %__MODULE__{}
    |> change(conversation_id: conversation_id, revision: Ecto.UUID.generate())
    |> put_limits(ExecutionLimits.normalize(limits))
    |> validate_required([:conversation_id, :revision])
    |> foreign_key_constraint(:conversation_id)
    |> unique_constraint(:conversation_id, name: :execution_allowances_pkey)
  end

  @doc "Narrow the saved allowance, retaining omitted fields and checking its revision."
  def narrow_changeset(%__MODULE__{} = allowance, request) do
    allowance
    |> change()
    |> put_limits(ExecutionLimits.for_resume(nil, nil, allowance.limits, request))
    |> optimistic_lock(:revision, fn _ -> Ecto.UUID.generate() end)
  end

  defp put_limits(changeset, {:ok, limits}), do: put_change(changeset, :limits, limits)

  defp put_limits(changeset, {:error, {reason, field}}),
    do: add_error(changeset, :limits, "#{reason}: #{field}")
end
