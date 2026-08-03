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

  require Logger

  alias Fountain.Audit.AdminEvent
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
  Record an administrative action taken against another user.

  Separate from `record/1` because these need both an actor and a target, which
  `audit_events` cannot express. Best-effort on the same terms.
  """
  @spec record_admin(map()) :: {:ok, AdminEvent.t()} | {:error, term()}
  def record_admin(attrs) do
    attrs =
      attrs
      |> Map.new()
      |> Map.put_new(:metadata, %{})
      |> Map.put_new(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))

    case %AdminEvent{} |> AdminEvent.changeset(attrs) |> Repo.insert() do
      {:ok, _} = ok ->
        ok

      {:error, changeset} = err ->
        # Callers ignore this return by design (best-effort), so a rejected
        # write — usually an event type missing from the AdminEvent allowlist
        # — silently erased its privilege-trail row. Twice, before #451. Log
        # at error and count it so the drop is visible and alertable.
        admin_record_lost(attrs, changeset.errors)
        err
    end
  rescue
    e ->
      admin_record_lost(attrs, e)
      {:error, :exception}
  end

  defp admin_record_lost(attrs, reason) do
    event_type = to_string(attrs[:event_type] || "unknown")

    Logger.error(
      "audit: admin event REJECTED, no privilege-trail row written " <>
        "(event_type=#{event_type}): #{inspect(reason)}"
    )

    :telemetry.execute(
      [:fountain, :audit, :admin_record_rejected],
      %{count: 1},
      %{event_type: event_type}
    )
  end

  @doc "Most recent administrative actions, newest first. Admin surfaces only."
  @spec _unsafe_list_recent_admin(pos_integer()) :: [AdminEvent.t()]
  def _unsafe_list_recent_admin(limit \\ 100) do
    Repo.all(from e in AdminEvent, order_by: [desc: e.inserted_at, desc: e.id], limit: ^limit)
  end

  @doc """
  Administrative actions taken against one user, newest first. Admin surfaces
  only — this is the "what happened to account Y" half of the support story.
  """
  @spec _unsafe_list_admin_events_for_target(Ecto.UUID.t(), pos_integer()) :: [AdminEvent.t()]
  def _unsafe_list_admin_events_for_target(target_user_id, limit \\ 50)
      when is_binary(target_user_id) do
    Repo.all(
      from e in AdminEvent,
        where: e.target_user_id == ^target_user_id,
        order_by: [desc: e.inserted_at, desc: e.id],
        limit: ^limit
    )
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
