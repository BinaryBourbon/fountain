defmodule Fountain.Audit.Event do
  @moduledoc """
  An audit log entry. Append-only — there is no update / delete path.

  `user_id` attributes the event to a tenant; nullable for system events
  and pre-tenancy backfill rows. `actor` is a coarse surface label
  (`"api"`, `"ui"`, `"cli"`, `"system"`) kept for grouping. `metadata`
  is a free-form bag.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User

  @foreign_key_type :binary_id

  schema "audit_events" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :string
    field :actor, :string
    field :request_ip, :string
    field :metadata, :map, default: %{}
    field :inserted_at, :utc_datetime
    belongs_to :user, User
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
      :inserted_at,
      :user_id
    ])
    |> validate_required([:action, :resource_type, :inserted_at])
  end
end
