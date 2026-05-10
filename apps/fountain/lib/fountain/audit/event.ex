defmodule Fountain.Audit.Event do
  @moduledoc """
  An audit log entry. Append-only — there is no update / delete path.

  Single-tenant, so `actor` is just a label (`"api"`, `"ui"`,
  `"cli"`, `"system"`) rather than a user reference. `metadata` is a
  free-form bag.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "audit_events" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :actor, :string
    field :request_ip, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime
  end

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :action,
      :resource_type,
      :resource_id,
      :actor,
      :request_ip,
      :metadata,
      :inserted_at
    ])
    |> validate_required([:action, :resource_type, :inserted_at])
  end
end
