defmodule Fountain.Audit.AdminEvent do
  @moduledoc """
  An administrative action taken by one user against another.

  The `admin_audit_events` table was created at launch and then never used —
  no schema module, no writer, no reader. So granting or revoking the admin
  role, the single most privilege-sensitive action in the product, left no
  record anywhere.

  It is a separate table from `audit_events` because it needs a shape that one
  cannot express: an actor *and* a target. `audit_events.user_id` is the tenant
  an event belongs to, which is ambiguous when an admin acts on someone else's
  account — the row would either lose the actor or lose the subject.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :id, autogenerate: true}

  @type t :: %__MODULE__{}
  schema "admin_audit_events" do
    # nil for system-originated actions
    field :actor_user_id, :binary_id
    field :target_user_id, :binary_id
    field :event_type, :string
    field :metadata, :map, default: %{}
    # Write-once; there is deliberately no updated_at.
    field :inserted_at, :utc_datetime
  end

  # Closed allowlist: an unknown type fails validation and record_admin/1
  # swallows the error, so an event type missing from this list is silently
  # never recorded. That already happened once — admin.account.deleted shipped
  # in the deletion work without being added here, and admin deletions left no
  # audit row until the admin billing work tripped over the same behaviour.
  @event_types ~w(
    admin.role.granted
    admin.role.revoked
    admin.sandbox_limit.changed
    admin.account.deleted
    admin.trial.extended
    admin.comp.granted
    admin.comp.revoked
    admin.sandbox.reaped
  )

  def event_types, do: @event_types

  def changeset(event, attrs) do
    event
    |> cast(attrs, [:actor_user_id, :target_user_id, :event_type, :metadata, :inserted_at])
    |> validate_required([:event_type, :inserted_at])
    |> validate_inclusion(:event_type, @event_types)
  end
end
