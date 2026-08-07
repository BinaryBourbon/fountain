defmodule Fountain.Funnel do
  @moduledoc """
  Lifecycle funnel: registered → verified → onboarded → activated → subscribed.

  Admin-only aggregates (no tenant scoping — callers are the admin panel and
  the metrics poller). Answers two operator questions:

  - `summary_admin/0` — how many users reach each stage, the conversion from
    the previous stage, and the median time between stages.
  - included stall breakdown — of the users who verified but never started a
    conversation, how far did they get? This is the "38 verified, zero
    conversations" question: did they finish onboarding, build an agent,
    create an environment, or bounce straight off?

  Stage definitions:

  - **registered** — a `users` row exists
  - **verified** — `email_verified_at` set
  - **onboarded** — `onboarding_completed_at` set
  - **activated** — first conversation: the earliest of a `conversations` row
    or a `sandbox_provisioned` usage event. The union matters: conversations
    can be deleted, usage events predate nothing after metering (#213) — either
    alone under-counts.
  - **subscribed** — `subscription_status` in active/past_due. Comped accounts
    are operator-granted, not conversions, and are excluded; converted-then-
    canceled users drop out of this stage (a churn view is #286's job).

  Everything is computed from one pass over `users` plus two grouped min
  queries — O(users) in memory, which is fine well past 10k users; push the
  math into SQL if that stops being true.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations.Conversation
  alias Fountain.Repo

  @subscribed_statuses ~w(active past_due)

  @type stage :: %{
          key: atom(),
          count: non_neg_integer(),
          conversion: float() | nil,
          median_hours: float() | nil
        }

  @doc """
  The funnel: five stages plus the stalled-at-activation breakdown.

  Returns `%{stages: [stage], stalled: %{count: n, by_onboarding_state: map,
  built_agent: n, built_environment: n, built_nothing: n}}`.

  `conversion` is the fraction of the *previous* stage (nil for registered);
  `median_hours` is the median time from the previous stage's timestamp, for
  users that have both (nil for registered and subscribed — there is no
  subscribed-at timestamp to measure against).
  """
  @spec summary_admin() :: %{stages: [stage()], stalled: map()}
  def summary_admin do
    users =
      Repo.all(
        from u in User,
          select: %{
            id: u.id,
            registered_at: u.inserted_at,
            verified_at: u.email_verified_at,
            onboarded_at: u.onboarding_completed_at,
            onboarding_state: u.onboarding_state,
            subscription_status: u.subscription_status
          }
      )

    first_activity = first_activity_by_user()

    registered = users
    verified = Enum.filter(users, & &1.verified_at)
    onboarded = Enum.filter(users, & &1.onboarded_at)
    activated = Enum.filter(users, &Map.has_key?(first_activity, &1.id))

    # With billing disabled there is nothing to subscribe to; statuses are nil
    # for accounts registered that way (#480), but pre-disable residue must not
    # count either. The stage stays in the list at 0 so the telemetry gauge
    # keeps its shape — the admin panel hides the tile (#481).
    subscribed =
      if Fountain.Billing.enabled?(),
        do: Enum.filter(users, &(&1.subscription_status in @subscribed_statuses)),
        else: []

    stages = [
      %{key: :registered, count: length(registered), conversion: nil, median_hours: nil},
      %{
        key: :verified,
        count: length(verified),
        conversion: ratio(length(verified), length(registered)),
        median_hours: median_hours(verified, & &1.registered_at, & &1.verified_at)
      },
      %{
        key: :onboarded,
        count: length(onboarded),
        conversion: ratio(length(onboarded), length(verified)),
        median_hours: median_hours(onboarded, & &1.verified_at, & &1.onboarded_at)
      },
      %{
        key: :activated,
        count: length(activated),
        conversion: ratio(length(activated), length(onboarded)),
        median_hours: median_hours(activated, & &1.onboarded_at, &Map.get(first_activity, &1.id))
      },
      %{
        key: :subscribed,
        count: length(subscribed),
        conversion: ratio(length(subscribed), length(activated)),
        median_hours: nil
      }
    ]

    %{stages: stages, stalled: stalled_breakdown(verified, first_activity)}
  end

  @doc """
  Poller hook for `FountainWeb.Telemetry.periodic_measurements/0`: emits stage
  counts as a `[:fountain, :funnel]` telemetry event so Prometheus/Grafana can
  trend them. Counts only — no medians (a median makes a poor gauge).
  """
  @spec emit_telemetry() :: :ok
  def emit_telemetry do
    # Guarded because telemetry_poller permanently drops a measurement
    # whose tick fails in any class — see Fountain.TelemetryTick (#365, #395).
    Fountain.TelemetryTick.run("funnel telemetry", fn ->
      %{stages: stages, stalled: %{count: stalled}} = summary_admin()

      measurements =
        stages
        |> Map.new(fn %{key: key, count: count} -> {key, count} end)
        |> Map.put(:stalled_verified, stalled)

      :telemetry.execute([:fountain, :funnel], measurements, %{})
    end)
  end

  # Of the verified users with no conversation ever: how far did each get?
  defp stalled_breakdown(verified, first_activity) do
    stalled = Enum.reject(verified, &Map.has_key?(first_activity, &1.id))
    stalled_ids = MapSet.new(stalled, & &1.id)

    agent_owners = owners_in(Fountain.Agents.Agent, stalled_ids)
    env_owners = owners_in(Fountain.Environments.Environment, stalled_ids)

    built_nothing =
      Enum.count(stalled, fn u ->
        not MapSet.member?(agent_owners, u.id) and not MapSet.member?(env_owners, u.id)
      end)

    %{
      count: length(stalled),
      by_onboarding_state: Enum.frequencies_by(stalled, & &1.onboarding_state),
      built_agent: MapSet.size(agent_owners),
      built_environment: MapSet.size(env_owners),
      built_nothing: built_nothing
    }
  end

  defp owners_in(schema, stalled_ids) do
    ids = MapSet.to_list(stalled_ids)

    from(r in schema, where: r.user_id in ^ids, distinct: true, select: r.user_id)
    |> Repo.all()
    |> MapSet.new()
  end

  # %{user_id => first-ever conversation timestamp}, from the union of the
  # conversations table and sandbox_provisioned usage events.
  defp first_activity_by_user do
    conversations =
      Repo.all(
        from c in Conversation,
          group_by: c.user_id,
          select: {c.user_id, min(c.inserted_at)}
      )

    usage =
      Repo.all(
        from e in UsageEvent,
          where: e.event_type == "sandbox_provisioned",
          group_by: e.user_id,
          select: {e.user_id, min(e.inserted_at)}
      )

    Map.merge(Map.new(conversations), Map.new(usage), fn _id, a, b ->
      if DateTime.compare(a, b) == :lt, do: a, else: b
    end)
  end

  defp ratio(_num, 0), do: nil
  defp ratio(num, denom), do: num / denom

  defp median_hours(users, from_fun, to_fun) do
    diffs =
      for u <- users,
          from_ts = from_fun.(u),
          to_ts = to_fun.(u),
          not is_nil(from_ts) and not is_nil(to_ts) do
        DateTime.diff(to_ts, from_ts, :second) / 3600
      end

    median(diffs)
  end

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    mid = div(length(sorted), 2)

    if rem(length(sorted), 2) == 1 do
      Enum.at(sorted, mid)
    else
      (Enum.at(sorted, mid - 1) + Enum.at(sorted, mid)) / 2
    end
  end
end
