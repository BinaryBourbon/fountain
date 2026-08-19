defmodule Fountain.Conversations.Turn do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.{Conversation, TurnImage}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed interrupted)

  schema "turns" do
    field :turn_number, :integer
    field :prompt, :string
    field :status, :string, default: "pending"
    field :exit_code, :integer
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    # JSON-RPC id of the ACP `session/prompt` in flight; nil on the legacy
    # path and until the peer has written the prompt. See the migration.
    field :acp_prompt_id, :integer
    # The turn's token usage as the runtime reported it when the turn ended
    # (#827): `%{"input" => n, "output" => n, "cache_read" => n?,
    # "cache_write" => n?}`. Written once by `Conversations._unsafe_record_turn_usage/2`,
    # never summed from the live `usage_update`s (their meaning differs per
    # runtime). nil when the runtime reported nothing.
    field :usage, :map
    belongs_to :conversation, Conversation
    has_many :images, TurnImage, preload_order: [asc: :position]
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def statuses, do: @statuses

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :turn_number,
      :prompt,
      :status,
      :exit_code,
      :started_at,
      :ended_at,
      :acp_prompt_id,
      :usage,
      :conversation_id
    ])
    |> validate_required([:turn_number, :prompt, :status, :conversation_id])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint([:conversation_id, :turn_number])
  end
end
