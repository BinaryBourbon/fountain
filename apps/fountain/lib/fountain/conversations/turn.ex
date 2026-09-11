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
    # runtime). Optional "accounting" preserves adapter scope/version/completeness;
    # it may be the only key when token counts are unknown. nil when nothing was reported.
    #
    # Two more keys, written at turn start rather than at its end (#1685):
    # "inference" (and, on a platform turn, "model") — see
    # `inference_stamp_only?/1`.
    field :usage, :map
    # ACP selection evidence, distinct from the agent's saved configuration.
    field :model_selection, :map
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

  # The two keys the turn-start inference stamp writes (#1685). Both are also
  # written by `TurnMachine.with_inference/2` at the end of a turn that
  # answers its prompt, which is why the late write merges over the early one
  # rather than colliding with it.
  @inference_stamp_keys ~w(inference model)

  @doc """
  Whether this `usage` map is the turn-start inference stamp and nothing else
  (#1685) — the turn ran on a known inference source, and no token figure has
  been recorded for it.

  Such a row exists so the platform-inference pass can see the turn at all: a
  turn that ends any way other than a `session/prompt` response never reaches
  `{:done, ...}`, and before #1685 left no trace of whose key it spent. It is
  not an end-of-turn usage record, so the two places that treat a usage map as
  one — the "already recorded" refusal in
  `Conversations._unsafe_record_turn_usage/2` and the API's turn `usage` field
  — ask this first.

  An `"accounting"`-only map (a runtime that reported its scope but no counts)
  is *not* a stamp: that is a real end-of-turn record, and a second one must
  still be refused.
  """
  @spec inference_stamp_only?(map()) :: boolean()
  def inference_stamp_only?(%{} = usage), do: Map.keys(usage) -- @inference_stamp_keys == []

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
      :model_selection,
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
