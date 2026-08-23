defmodule Fountain.SandboxQueue.Request do
  @moduledoc """
  One queued sandbox request (#1033, ADR 0030) — work that hit the per-tenant
  concurrency cap and is waiting for a free slot instead of being refused.

  `kind` says what the drainer does with a won slot:

    * `"start"` — `attrs` holds the original conversation-create attrs
      (JSON-safe: images are refused at enqueue) and the drainer calls
      `Conversations.start_conversation/2`.
    * `"schedule_run"` — `schedule_id` names a team schedule and the drainer
      re-fires `Team.Schedules.run_schedule/2`; `attrs` stays empty.

  A request is terminal in exactly one of `started` (conversation_id set for
  `start`), `cancelled` (the owner withdrew it), `expired` (waited past the
  bound) or `failed` (`error` says why). It never becomes a conversation
  status — a queued start has no sandbox, and the conversation exists only
  once the slot is won.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(start schedule_run)
  @statuses ~w(queued started cancelled expired failed)

  schema "sandbox_requests" do
    field :kind, :string, default: "start"
    field :attrs, :map, default: %{}
    field :schedule_id, :binary_id
    field :source, :string
    field :status, :string, default: "queued"
    field :error, :string
    belongs_to :user, User
    belongs_to :agent, Agent
    belongs_to :conversation, Conversation
    # Microsecond precision: queue order is FIFO by inserted_at, and two
    # requests inside the same second must not order arbitrarily.
    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "Internal changeset — requests are written by the context, never cast from user input wholesale."
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :kind,
      :attrs,
      :schedule_id,
      :source,
      :status,
      :error,
      :user_id,
      :agent_id,
      :conversation_id
    ])
    |> validate_required([:kind, :status, :user_id, :agent_id])
    |> validate_inclusion(:kind, @kinds)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:agent_id)
  end
end
