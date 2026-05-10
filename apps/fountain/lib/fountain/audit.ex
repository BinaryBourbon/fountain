defmodule Fountain.Audit do
  @moduledoc """
  Append-only audit log for admin actions.

  Single-tenant, so this is more of a "what just happened" feed than an
  authorization trail. Useful when something gets deleted unexpectedly,
  or when you want to know which surface (api/ui/cli) triggered a
  conversation.

  Logging is best-effort: a log failure must never break the operation
  it's recording. Use `record!/1` only when you can tolerate raising;
  default to `record/1`.
  """

  import Ecto.Query

  alias Fountain.Audit.Event
  alias Fountain.Repo

  @type attrs :: %{
          required(:action) => String.t(),
          required(:resource_type) => String.t(),
          optional(:resource_id) => String.t() | nil,
          optional(:actor) => String.t() | nil,
          optional(:request_ip) => String.t() | nil,
          optional(:metadata) => map()
        }

  @spec record(attrs()) :: {:ok, Event.t()} | {:error, term()}
  def record(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case %Event{} |> Event.changeset(attrs) |> Repo.insert() do
      {:ok, _} = ok -> ok
      {:error, _} = err -> err
    end
  rescue
    e ->
      require Logger
      Logger.warning("audit: record failed: #{inspect(e)}")
      {:error, :exception}
  end

  @spec record!(attrs()) :: Event.t()
  def record!(attrs) do
    {:ok, event} = record(attrs)
    event
  end

  @doc "List the most recent N events, newest first."
  def list_recent(limit \\ 200) do
    Repo.all(from e in Event, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end

  @doc "List events for one resource."
  def list_for(resource_type, resource_id, limit \\ 50) do
    Repo.all(
      from e in Event,
        where: e.resource_type == ^resource_type and e.resource_id == ^resource_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end
end
