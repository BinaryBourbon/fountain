defmodule Fountain.Conversations.Turn do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.{Conversation, TurnImage}

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(pending running completed failed interrupted)
  # `user`: a prompt somebody sent. `autonomous`: a turn the server opened
  # for a background cycle that ran after the prompt was answered (#817) —
  # the prompt column then carries a marker, not a person's words.
  @origins ~w(user autonomous)

  schema "turns" do
    field :turn_number, :integer
    field :prompt, :string
    field :status, :string, default: "pending"
    field :exit_code, :integer
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime
    # Set when Fountain, rather than the runtime or the user, reconciles a
    # running turn that no longer has anything driving it. Billing and usage
    # exclude these intervals because the true end of work is unknowable.
    field :orphaned_at, :utc_datetime
    # JSON-RPC id of the ACP `session/prompt` in flight; nil on the legacy
    # path and until the peer has written the prompt. See the migration.
    field :acp_prompt_id, :integer
    # The `session/request_permission` this turn is blocked on (#940): the
    # agent's JSON-RPC id, the tool, and the options it offered. nil whenever
    # nothing is outstanding. Persisted so a request raised before a deploy is
    # still answerable after one.
    field :pending_permission, :map
    # The turn's token usage as the runtime reported it when the turn ended
    # (#827): `%{"input" => n, "output" => n, "cache_read" => n?,
    # "cache_write" => n?}`. Written once by `Conversations._unsafe_record_turn_usage/2`,
    # never summed from the live `usage_update`s (their meaning differs per
    # runtime). nil when the runtime reported nothing.
    field :usage, :map
    # The assistant's text for the turn — its events' `text` blocks, joined —
    # materialised by `Conversations._unsafe_update_turn/2` when the turn
    # ends, for `Fountain.Search` (#826). nil while the turn runs and on
    # turns that predate the column (see `Fountain.Release.backfill_turn_replies/0`).
    field :reply_text, :string
    field :origin, :string, default: "user"
    belongs_to :conversation, Conversation
    has_many :images, TurnImage, preload_order: [asc: :position]
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def statuses, do: @statuses
  def origins, do: @origins

  def changeset(turn, attrs) do
    turn
    |> cast(attrs, [
      :turn_number,
      :prompt,
      :status,
      :exit_code,
      :started_at,
      :ended_at,
      :orphaned_at,
      :acp_prompt_id,
      :pending_permission,
      :usage,
      :reply_text,
      :origin,
      :conversation_id
    ])
    |> validate_required([:turn_number, :prompt, :status, :conversation_id])
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:origin, @origins)
    |> unique_constraint([:conversation_id, :turn_number])
  end
end
