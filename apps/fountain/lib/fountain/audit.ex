defmodule Fountain.Audit do
  @moduledoc """
  Append-only audit log for state-changing actions.

  Each event is attributed to a tenant via `user_id`. Pre-tenancy rows
  and system-originated events have `user_id = nil` and are only
  surfaced through admin views.

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
          optional(:metadata) => map(),
          optional(:user_id) => Ecto.UUID.t() | nil
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

  @doc """
  List the most recent N events for one tenant, newest first.

  System events (`user_id = nil`) are excluded — those belong to admin
  views via `_unsafe_list_recent/1`.
  """
  @spec list_recent_for_user(Ecto.UUID.t(), pos_integer()) :: [Event.t()]
  def list_recent_for_user(user_id, limit \\ 200) when is_binary(user_id) do
    Repo.all(
      from e in Event,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end

  @doc """
  Unscoped: every event in the system, regardless of tenant.

  Reserved for admin/system surfaces. Anything user-facing must use
  `list_recent_for_user/2` instead.
  """
  @spec _unsafe_list_recent(pos_integer()) :: [Event.t()]
  def _unsafe_list_recent(limit \\ 200) do
    Repo.all(from e in Event, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end

  @doc """
  List events for one resource, scoped to a tenant.
  """
  @spec list_for(String.t(), String.t(), Ecto.UUID.t(), pos_integer()) :: [Event.t()]
  def list_for(resource_type, resource_id, user_id, limit \\ 50)
      when is_binary(user_id) do
    Repo.all(
      from e in Event,
        where:
          e.resource_type == ^resource_type and e.resource_id == ^resource_id and
            e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
  end
end
