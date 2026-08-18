defmodule Fountain.Team.Schedule do
  @moduledoc """
  A scheduled prompt for a teammate: on a cron, send `prompt` to the agent.

  `one_off` decides *where* it runs. `false` (the default) sends the prompt
  into the teammate's own conversation — the one `/team` shows — as if the
  user had typed it, so the reply lands in the thread and the agent's
  working memory. `true` opens a fresh conversation on a new computer for
  each run, using the same agent, environment and vault the teammate has,
  and leaves the teammate's thread alone; the run shows up in
  `/conversations` like any other.

  `cron` is a five-field expression in UTC (`Oban.Cron.Expression` is the
  parser, so `@daily`-style names work too; `@reboot` does not — a schedule
  needs a next time). `next_run_at` is derived from it and is what the
  ticker polls; the context recomputes it whenever the cron changes or the
  schedule is re-enabled.
  """
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.Conversation

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "team_schedules" do
    field :name, :string
    field :cron, :string
    field :prompt, :string
    field :one_off, :boolean, default: false
    field :enabled, :boolean, default: true
    field :next_run_at, :utc_datetime
    field :last_run_at, :utc_datetime
    field :last_error, :string

    belongs_to :user, User
    belongs_to :agent, Agent
    belongs_to :last_conversation, Conversation

    timestamps(type: :utc_datetime)
  end

  @doc "The user-editable fields."
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:name, :cron, :prompt, :one_off, :enabled, :agent_id, :user_id])
    |> validate_required([:cron, :prompt, :agent_id, :user_id])
    |> update_change(:name, &blank_to_nil/1)
    |> update_change(:cron, &String.trim/1)
    |> validate_length(:name, max: 120)
    |> validate_length(:prompt, min: 1, max: 20_000)
    |> validate_cron()
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:user_id)
  end

  @doc "The fields a run writes; not user-editable."
  def run_changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:next_run_at, :last_run_at, :last_error, :last_conversation_id])
    |> update_change(:last_error, &truncate_error/1)
  end

  @doc """
  Parses `cron`. `{:ok, expr}` for a usable expression, `{:error, message}`
  for anything else — including `@reboot`, which has no next time.
  """
  def parse_cron(cron) when is_binary(cron) do
    case Oban.Cron.Expression.parse(String.trim(cron)) do
      {:ok, %{reboot?: true}} -> {:error, "@reboot is not a schedule"}
      {:ok, expr} -> {:ok, expr}
      {:error, %ArgumentError{message: message}} -> {:error, message}
    end
  end

  def parse_cron(_), do: {:error, "is not a valid cron expression"}

  @doc "The next time `cron` fires strictly after `from` (UTC)."
  def next_run_at(cron, from \\ DateTime.utc_now()) do
    with {:ok, expr} <- parse_cron(cron) do
      case Oban.Cron.Expression.next_at(expr, from) do
        %DateTime{} = at -> {:ok, DateTime.truncate(at, :second)}
        :unknown -> {:error, "has no next run"}
      end
    end
  end

  defp validate_cron(changeset) do
    case fetch_change(changeset, :cron) do
      {:ok, cron} ->
        case parse_cron(cron) do
          {:ok, _} -> changeset
          {:error, message} -> add_error(changeset, :cron, message)
        end

      :error ->
        changeset
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  # A `:string` column; an inspected error term can be long.
  defp truncate_error(nil), do: nil
  defp truncate_error(msg) when is_binary(msg), do: String.slice(msg, 0, 250)
end
