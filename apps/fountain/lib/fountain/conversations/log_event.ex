defmodule Fountain.Conversations.LogEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.{Conversation, Turn}

  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @kinds ~w(output stage)
  # `acp` rows hold Agent Client Protocol `session/update` notifications, one
  # per line, exactly as `stdout` rows hold raw runtime output — what is on disk
  # is what the agent actually said. The render path tells them apart by stream
  # rather than by the conversation's runtime, so a conversation whose agent had
  # the flag flipped mid-way renders its earlier turns through the legacy parser
  # and its later ones through ACP. See decisions/0014.
  @streams ~w(stdout stderr acp)
  @states ~w(started done failed interrupted)

  schema "log_events" do
    field :kind, :string
    field :stream, :string, default: ""
    field :data, :string, default: ""
    field :stage, :string, default: ""
    field :state, :string, default: ""
    field :duration_ms, :integer
    field :inserted_at, :utc_datetime_usec
    belongs_to :conversation, Conversation
    belongs_to :turn, Turn
  end

  def kinds, do: @kinds
  def streams, do: @streams
  def states, do: @states

  @doc """
  `state` as the API renders it: `nil` for an event that has no state.

  The column is `NOT NULL DEFAULT ''`, so "no state" is stored as `""` on every
  row this table has ever held. The published schema says the field is one of
  `#{Enum.join(@states, " ")}` or `null` — `""` is neither, and a generated
  client with a strict enum decoder is entitled to reject an ordinary output
  event on the busiest read in the API (#1430).

  Converting here rather than on the way in keeps one representation on disk
  and one on the wire, with a single named conversion between them. Storing
  `nil` instead would mean dropping a `NOT NULL` on `log_events`, the
  highest-volume table in the system, and would still need this function for
  every row written before that migration.
  """
  @spec rendered_state(t()) :: String.t() | nil
  def rendered_state(%__MODULE__{state: state}), do: blank_to_nil(state)

  @doc """
  `stage` as the API renders it: `nil` for an event that has no stage.

  Follows `rendered_state/1`. `stage` has no enum to violate, so this is not a
  contract fix but a consistency one: an output event that answered `null` for
  its state and `""` for its stage would be describing the same absence two
  ways.
  """
  @spec rendered_stage(t()) :: String.t() | nil
  def rendered_stage(%__MODULE__{stage: stage}), do: blank_to_nil(stage)

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  def changeset(event, attrs) do
    event
    |> cast(attrs, [
      :kind,
      :stream,
      :data,
      :stage,
      :state,
      :duration_ms,
      :inserted_at,
      :conversation_id,
      :turn_id
    ])
    |> validate_required([:kind, :conversation_id, :inserted_at])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:stream, ["" | @streams])
    |> validate_inclusion(:state, ["" | @states])
  end
end
