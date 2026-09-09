defmodule Fountain.Broker.Native.Insights do
  @moduledoc """
  What the egress broker is doing, for `/admin/broker` (ADR 0019).

  Everything the broker knows is already on disk — `broker_sessions` says
  which conversations hold a proxy token, and `broker_requests` says what
  each brokered sandbox reached and whether a credential went with it — but
  until this module the only readers were a per-conversation API page and
  the Prometheus series. An operator asking "is the broker healthy, who is
  it brokering, and what is it denying" had to run SQL. This answers those
  three from one call.

  Every function here is `_unsafe_`: the queries span every tenant by
  design, and the one caller is the admin page behind `require_admin`.

  The numbers are bounded by a window (default the last 24 hours, selected
  from 1, 24 or 168 hours) and filter on `inserted_at`. A wide window can
  still read the full retained log, so traffic aggregates refresh only on
  operator action.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Accounts.User
  alias Fountain.Broker
  alias Fountain.Broker.Native.{Request, Session}
  alias Fountain.Repo

  @default_window_hours 24
  @windows [1, 24, 168]

  @doc "The windows the page offers, in hours."
  @spec windows() :: [pos_integer()]
  def windows, do: @windows

  @doc """
  The whole picture, in one map:

    * `:backend` / `:listener_up` / `:tenants` / `:ca_expires_at` /
      `:retention_hours` — the switch and its health, from configuration and
      the listener, not the database. A deployment that does not broker
      returns these with the rest empty, and the page says so.
    * `:sessions` — live rows, expired rows the reaper has not swept, and
      how many conversations hold one.
    * `:window` — request counts over the window by outcome, plus how many
      conversations and tenants produced them.
    * `:hosts` — the busiest hosts in the window with their outcome split.
    * `:services` — the bindings whose credential the proxy attached, and the
      variable names it attached (never a value).
    * `:denied` — the most recent refusals, each linked to its conversation.
    * `:errors` — how requests failed, by reason, in the window.
    * `:live_sessions` — the sessions themselves, soonest to expire first.

  `window_hours` is clamped to `windows/0`.
  """
  @spec _unsafe_overview_admin(pos_integer()) :: map()
  def _unsafe_overview_admin(window_hours \\ @default_window_hours) do
    hours = if window_hours in @windows, do: window_hours, else: @default_window_hours
    since = DateTime.add(DateTime.utc_now(), -hours, :hour)

    Map.merge(_unsafe_health_admin(), %{
      window_hours: hours,
      window: window_counts(since),
      hosts: top_hosts(since, 10),
      services: top_services(since, 10),
      denied: recent(since, :denied, 20),
      errors: error_counts(since),
      failed: recent(since, :failed, 10),
      live_sessions: live_sessions(50)
    })
  end

  @doc "Health information without request-log aggregates, for the automatic refresh."
  def _unsafe_health_admin do
    %{
      backend: Broker.backend(),
      configured: Broker.configured?(),
      listener_up: listener_up?(),
      tenants: Application.get_env(:fountain, :broker_tenants, []),
      retention_hours: Broker.log_retention_hours(),
      ca_expires_at: ca_expires_at(),
      sessions: session_counts()
    }
  end

  defp listener_up? do
    case Broker.preflight() do
      :ok -> true
      _ -> false
    end
  end

  # The derived CA's end, or nil where the broker is off. Read through the
  # same function the telemetry tick uses, so the page and the alert can
  # never disagree about the date.
  defp ca_expires_at do
    with :native <- Broker.backend(),
         {:ok, pem} <- Fountain.Broker.Native.ca_pem() do
      pem
      |> X509.Certificate.from_pem!()
      |> X509.Certificate.validity()
      |> elem(2)
      |> X509.DateTime.to_datetime()
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp session_counts do
    now = DateTime.utc_now()

    Repo.one(
      from s in Session,
        select: %{
          live: count(fragment("CASE WHEN ? > ? THEN 1 END", s.expires_at, ^now)),
          expired: count(fragment("CASE WHEN ? <= ? THEN 1 END", s.expires_at, ^now)),
          conversations:
            count(
              fragment(
                "DISTINCT CASE WHEN ? > ? THEN ? END",
                s.expires_at,
                ^now,
                s.conversation_id
              )
            )
        }
    )
  end

  defp window_counts(since) do
    Repo.one(
      from r in Request,
        where: r.inserted_at >= ^since,
        select: %{
          requests: count(r.id),
          conversations: count(r.conversation_id, :distinct),
          tenants: count(r.user_id, :distinct),
          injected: count(fragment("CASE WHEN ? = 'injected' THEN 1 END", r.outcome)),
          passthrough: count(fragment("CASE WHEN ? = 'passthrough' THEN 1 END", r.outcome)),
          denied: count(fragment("CASE WHEN ? = 'denied' THEN 1 END", r.outcome)),
          failed: count(r.error)
        }
    )
  end

  defp top_hosts(since, limit) do
    Repo.all(
      from r in Request,
        where: r.inserted_at >= ^since,
        group_by: r.host,
        order_by: [desc: count(r.id)],
        limit: ^limit,
        select: %{
          host: r.host,
          requests: count(r.id),
          injected: count(fragment("CASE WHEN ? = 'injected' THEN 1 END", r.outcome)),
          denied: count(fragment("CASE WHEN ? = 'denied' THEN 1 END", r.outcome)),
          failed: count(r.error)
        }
    )
  end

  # `credential_keys` is already the variable *names*, the same thing an
  # audit row records for a secret write; the values never reach this table.
  # Two reads rather than an aggregate over an array column: `array_agg` of
  # arrays needs every row the same length, which they are not.
  defp top_services(since, limit) do
    keys = keys_by_service(since)

    Repo.all(
      from r in Request,
        where: r.inserted_at >= ^since and r.outcome == "injected" and not is_nil(r.service),
        group_by: r.service,
        order_by: [desc: count(r.id)],
        limit: ^limit,
        select: %{
          service: r.service,
          requests: count(r.id),
          conversations: count(r.conversation_id, :distinct)
        }
    )
    |> Enum.map(&Map.put(&1, :credential_keys, Map.get(keys, &1.service, [])))
  end

  defp keys_by_service(since) do
    Repo.all(
      from r in Request,
        where: r.inserted_at >= ^since and r.outcome == "injected" and not is_nil(r.service),
        distinct: true,
        select: {r.service, fragment("unnest(?)", r.credential_keys)}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {service, names} -> {service, Enum.sort(names)} end)
  end

  # The rows an operator acts on: what was refused, and what broke. The
  # same columns either way, each linking to the conversation it came from.
  defp recent(since, :denied, limit),
    do: since |> recent_query(limit) |> where_outcome("denied") |> Repo.all()

  defp recent(since, :failed, limit),
    do: since |> recent_query(limit) |> where_failed() |> Repo.all()

  defp recent_query(since, limit) do
    from r in Request,
      left_join: u in User,
      on: u.id == r.user_id,
      where: r.inserted_at >= ^since,
      order_by: [desc: r.id],
      limit: ^limit,
      select: %{
        id: r.id,
        inserted_at: r.inserted_at,
        method: r.method,
        host: r.host,
        path: r.path,
        conversation_id: r.conversation_id,
        user_id: r.user_id,
        email: u.email,
        status: r.status,
        error: r.error
      }
  end

  defp where_outcome(query, outcome), do: from(r in query, where: r.outcome == ^outcome)
  defp where_failed(query), do: from(r in query, where: not is_nil(r.error))

  defp error_counts(since) do
    Repo.all(
      from r in Request,
        where: r.inserted_at >= ^since and not is_nil(r.error),
        group_by: r.error,
        order_by: [desc: count(r.id)],
        select: %{error: r.error, requests: count(r.id)}
    )
  end

  # Nothing decrypted: the rules stay ciphertext under the tenant's DEK and
  # this page never loads one. `meta` carries the rule-to-variable-names
  # map `prepare/4` stored, which is how many bindings the session brokers.
  defp live_sessions(limit) do
    now = DateTime.utc_now()

    Repo.all(
      from s in Session,
        left_join: u in User,
        on: u.id == s.user_id,
        where: s.expires_at > ^now,
        order_by: [asc: s.expires_at],
        limit: ^limit,
        select: %{
          id: s.id,
          conversation_id: s.conversation_id,
          user_id: s.user_id,
          email: u.email,
          policy: s.unmatched_host_policy,
          meta: s.meta,
          inserted_at: s.inserted_at,
          expires_at: s.expires_at
        }
    )
    |> Enum.map(fn s ->
      keys = s.meta |> Map.get("credential_keys", %{}) |> Map.values() |> List.flatten()
      %{s | meta: nil} |> Map.put(:credential_keys, keys |> Enum.uniq() |> Enum.sort())
    end)
  end
end
