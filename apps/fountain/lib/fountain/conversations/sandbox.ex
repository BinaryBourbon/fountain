defmodule Fountain.Conversations.Sandbox do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Conversation
  alias Fountain.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `suspended`: the sprite still exists at sprites.dev (scaled to zero on its
  # own) but no ConversationServer is attached. The durable resting state of an
  # idle conversation — not counted toward the concurrency quota, woken by the
  # next prompt via the reattach path. See decisions/0017.
  @statuses ~w(pending starting ready suspended terminated failed)

  schema "sandboxes" do
    # Provider-scoped sandbox identity: the name Fountain mints
    # (`fountain-<tenant-prefix>-<hex>`) and uses as the primary external ref.
    # The column name predates multiple providers and survives for API and
    # historical-metadata compatibility.
    field :sprite_name, :string
    field :status, :string, default: "pending"
    # Which sandbox backend owns this row. Stamped at creation and never
    # re-resolved: a parked sandbox wakes on the provider that holds its
    # disk, whatever the instance default is by then.
    field :provider, :string, default: "sprites"
    # Adapter-opaque state (e.g. a server-assigned id). Never tenant-visible.
    field :provider_meta, :map, default: %{}
    field :terminated_at, :utc_datetime
    field :last_resumed_at, :utc_datetime
    belongs_to :environment, Environment
    belongs_to :user, User
    has_many :conversations, Conversation
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, [
      :sprite_name,
      :status,
      :provider,
      :provider_meta,
      :terminated_at,
      :last_resumed_at,
      :environment_id,
      :user_id
    ])
    |> validate_required([:sprite_name, :status, :provider, :user_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:provider, Fountain.Sandbox.known_providers())
  end
end
