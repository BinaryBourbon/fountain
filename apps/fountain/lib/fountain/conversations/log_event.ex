defmodule Fountain.Conversations.LogEvent do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Conversations.{Conversation, Turn}

  @foreign_key_type :binary_id

  @kinds ~w(output stage)
  @streams ~w(stdout stderr)
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
