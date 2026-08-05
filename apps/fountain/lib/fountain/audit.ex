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
    list_for_user(user_id, limit: limit)
  end

  @doc """
  Tenant-scoped events, newest first, with filters and a cursor.

  Options:

    * `:limit` — page size (default 200)
    * `:before_id` — only events with a smaller id; the cursor for paging
      back through history, since the order is newest-first
    * `:action_prefix` — e.g. `"vault."` for everything vault-related.
      LIKE metacharacters in the value are escaped, so a prefix of `%` is a
      literal `%` and not "match everything"
    * `:resource_type` — exact match
    * `:since` / `:until` — `DateTime` bounds on `inserted_at`, inclusive

  Unknown options are ignored. The trail is append-only, so paging by id is
  stable: nothing is inserted behind the cursor.
  """
  @spec list_for_user(Ecto.UUID.t(), keyword()) :: [Event.t()]
  def list_for_user(user_id, opts \\ []) when is_binary(user_id) do
    from(e in Event,
      where: e.user_id == ^user_id,
      order_by: [desc: e.inserted_at, desc: e.id],
      limit: ^Keyword.get(opts, :limit, 200)
    )
    |> filter_before_id(Keyword.get(opts, :before_id))
    |> filter_action_prefix(Keyword.get(opts, :action_prefix))
    |> filter_resource_type(Keyword.get(opts, :resource_type))
    |> filter_since(Keyword.get(opts, :since))
    |> filter_until(Keyword.get(opts, :until))
    |> Repo.all()
  end

  defp filter_before_id(query, nil), do: query

  defp filter_before_id(query, id) when is_integer(id),
    do: from(e in query, where: e.id < ^id)

  defp filter_action_prefix(query, nil), do: query
  defp filter_action_prefix(query, ""), do: query

  defp filter_action_prefix(query, prefix) when is_binary(prefix) do
    from(e in query, where: like(e.action, ^(escape_like(prefix) <> "%")))
  end

  defp filter_resource_type(query, nil), do: query
  defp filter_resource_type(query, ""), do: query

  defp filter_resource_type(query, type) when is_binary(type),
    do: from(e in query, where: e.resource_type == ^type)

  defp filter_since(query, nil), do: query

  defp filter_since(query, %DateTime{} = since),
    do: from(e in query, where: e.inserted_at >= ^since)

  defp filter_until(query, nil), do: query

  defp filter_until(query, %DateTime{} = until),
    do: from(e in query, where: e.inserted_at <= ^until)

  # A caller-supplied prefix is a literal, not a pattern: without this,
  # `?action_prefix=%` would match the whole trail and `_` would be a
  # single-character wildcard.
  defp escape_like(value) do
    value
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
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
