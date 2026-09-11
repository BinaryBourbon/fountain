defmodule Fountain.SandboxQueue.Request do
  @moduledoc """
  Work waiting for sandbox capacity (#1033, ADR 0042).

  A request is its own row rather than a conversation status because it has no
  sandbox and no conversation yet. A `queued` conversation would leak a row
  with no machine into every conversation list, every stream and every client
  enum.

  `sandbox_key_id` is the restriction the request arrived under, not a
  credential: a `sprite`-scoped token may label only its own conversation
  (ADR 0045), and a replay an hour later has to be held to the same rule as
  the door. Absent means the caller had no sandbox restriction.

  `"start"` carries the JSON-safe launch attributes the API call arrived with.
  `"schedule_run"` carries a schedule id and re-fires that schedule. Every
  terminal transition erases `attrs`, so a finished row keeps provenance and
  an outcome but never a prompt.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @kinds ~w(start schedule_run)
  @statuses ~w(queued starting started cancelled expired failed)
  @active_statuses ~w(queued starting)

  @type t :: %__MODULE__{}

  schema "sandbox_requests" do
    field :kind, :string, default: "start"
    field :attrs, :map, default: %{}
    field :schedule_id, :binary_id
    field :sandbox_key_id, :binary_id
    field :source, :string
    field :status, :string, default: "queued"
    field :error, :string
    belongs_to :user, User
    belongs_to :agent, Agent
    belongs_to :conversation, Conversation
    timestamps(type: :utc_datetime_usec)
  end

  def kinds, do: @kinds
  def statuses, do: @statuses

  @doc "The statuses that mean live work, as opposed to a history row."
  def active_statuses, do: @active_statuses

  @doc """
  Internal changeset. Callers never cast request parameters wholesale — the
  queue builds the map itself from keys it names.
  """
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :kind,
      :attrs,
      :schedule_id,
      :sandbox_key_id,
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
