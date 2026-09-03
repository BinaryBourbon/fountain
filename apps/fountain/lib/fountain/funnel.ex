defmodule Fountain.Funnel do
  @moduledoc """
  Lifecycle funnel: registered → verified → onboarded → activated → funded.

  Admin-only aggregates (no tenant scoping — callers are the admin panel and
  the metrics poller). Answers three operator questions:

  - `summary_admin/0` — how many users reach each stage, the conversion from
    the previous stage, and the median time between stages.
  - **time to first reply** — verification to the first reply, median and p90,
    plus the share of accounts that get there inside a day. This is the number
    ADR 0038 says the onboarding redesign is judged on.
  - included stall breakdown — of the users who verified but never got a
    reply, how far did they get? This is the "40 verified, nothing created"
    question: did they finish onboarding, build an agent, create an
    environment, start a conversation that never answered, or bounce straight
    off?

  Stage definitions:

  - **registered** — a `users` row exists
  - **verified** — `email_verified_at` set
  - **onboarded** — `onboarding_completed_at` set. Since #867 that means the
    account has an inference credential and an agent (the console stamps it),
    rather than "clicked through the wizard"; ADR 0038 moves the stamp to the
    first reply, which is `Fountain.Activation`'s seam. `by_onboarding_state`
    in the stall breakdown is the vestige of that wizard — it now only
    distinguishes `step_1` from `completed`; `built_agent` /
    `built_environment` / `built_nothing` are the live signal.
  - **activated** — **the first conversation with a reply** (ADR 0038): the
    earliest `turns` row for the account carrying a non-empty `reply_text`.
    A conversation that never answered does not count, and neither does a
    sandbox that was provisioned for one. Until #1392 this stage was the
    union of a `conversations` row and a `sandbox_provisioned` usage event,
    which counted an attempt as an outcome; the union survives one stage
    down, in `stalled.started`, where "started something and got nothing" is
    exactly what it witnesses.
  - **funded** — holds a positive credit balance (ADR 0031). Comped accounts
    are operator-granted, not conversions, and are excluded; an account that
    spent its balance to zero drops out of this stage (a churn view is #286's
    job).

  Everything is computed from one pass over `users` plus a handful of grouped
  min queries — O(users) in memory, which is fine well past 10k users; push
  the math into SQL if that stops being true.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Accounts.User
  alias Fountain.Activation
  alias Fountain.Billing.UsageEvent
  alias Fountain.Conversations.Conversation
  alias Fountain.Repo

  # A day, in hours: the window ADR 0038 judges the landing by.
  @day_hours 24

  @type stage :: %{
          key: atom(),
          count: non_neg_integer(),
          conversion: float() | nil,
          median_hours: float() | nil
        }

  @type timing :: %{
          count: non_neg_integer(),
          median_hours: float() | nil,
          p90_hours: float() | nil,
          within_day: non_neg_integer(),
          within_day_of: non_neg_integer(),
          within_day_share: float() | nil
        }

  @doc """
  The funnel: five stages, time to first reply, and the stalled breakdown.

  Returns `%{stages: [stage], time_to_first_reply: timing, stalled: %{count: n,
  by_onboarding_state: map, started: n, built_agent: n, built_environment: n,
  built_nothing: n}}`.

  `conversion` is the fraction of the *previous* stage (nil for registered);
  `median_hours` is the median time from the previous stage's timestamp, for
  users that have both (nil for registered and funded — there is no
  funded-at timestamp to measure against).
  """
  @spec summary_admin() :: %{stages: [stage()], time_to_first_reply: timing(), stalled: map()}
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
            credit_balance_cents: u.credit_balance_cents
          }
      )

    first_reply = Activation.first_reply_by_user()

    registered = users
    verified = Enum.filter(users, & &1.verified_at)
    onboarded = Enum.filter(users, & &1.onboarded_at)
    activated = Enum.filter(users, &Map.has_key?(first_reply, &1.id))

    # Funded: a positive credit balance (ADR 0031). With billing disabled
    # nothing is granted or sold, so the stage stays in the list at 0 to keep
    # the telemetry gauge's shape — the admin panel hides the tile (#481).
    funded =
      if Fountain.Credits.enabled?(),
        do: Enum.filter(users, &(&1.credit_balance_cents > 0)),
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
        median_hours: median_hours(activated, & &1.onboarded_at, &Map.get(first_reply, &1.id))
      },
      %{
        key: :funded,
        count: length(funded),
        conversion: ratio(length(funded), length(activated)),
        median_hours: nil
      }
    ]

    %{
      stages: stages,
      time_to_first_reply: time_to_first_reply(verified, first_reply),
      stalled: stalled_breakdown(verified, first_reply)
    }
  end

  @doc """
  Poller hook for `FountainWeb.Telemetry.periodic_measurements/0`: emits stage
  counts as a `[:fountain, :funnel]` telemetry event so Prometheus/Grafana can
  trend them. Counts only — no medians (a median makes a poor gauge, and time
  to first reply is a PostHog question because it wants an account attached).

  Every replica polls the same database and reports the same number, so a
  Grafana panel over these aggregates with `max`, never `sum`.
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

  # Verification to the first reply, over the accounts that have both.
  #
  # `within_day_share` deliberately does not divide by every verified account.
  # An account verified an hour ago has not failed to reply within a day; it
  # has not had a day. The denominator is the accounts a full day has passed
  # for, which is a number that can only be read one way and can never exceed
  # its numerator.
  defp time_to_first_reply(verified, first_reply) do
    now = DateTime.utc_now()

    hours =
      for u <- verified,
          reply_at = Map.get(first_reply, u.id),
          not is_nil(reply_at) do
        {u, DateTime.diff(reply_at, u.verified_at, :second) / 3600}
      end

    judged =
      Enum.filter(verified, fn u ->
        DateTime.diff(now, u.verified_at, :second) / 3600 >= @day_hours
      end)

    judged_ids = MapSet.new(judged, & &1.id)

    within_day =
      Enum.count(hours, fn {u, h} -> h <= @day_hours and MapSet.member?(judged_ids, u.id) end)

    values = Enum.map(hours, &elem(&1, 1))

    %{
      count: length(values),
      median_hours: median(values),
      p90_hours: percentile(values, 0.9),
      within_day: within_day,
      within_day_of: length(judged),
      within_day_share: ratio(within_day, length(judged))
    }
  end

  # Of the verified users who never got a reply: how far did each get?
  defp stalled_breakdown(verified, first_reply) do
    stalled = Enum.reject(verified, &Map.has_key?(first_reply, &1.id))
    stalled_ids = MapSet.new(stalled, & &1.id)

    agent_owners = owners_in(Fountain.Agents.Agent, stalled_ids)
    env_owners = owners_in(Fountain.Environments.Environment, stalled_ids)
    starters = started_ids(stalled_ids)

    built_nothing =
      Enum.count(stalled, fn u ->
        not MapSet.member?(agent_owners, u.id) and not MapSet.member?(env_owners, u.id)
      end)

    %{
      count: length(stalled),
      by_onboarding_state: Enum.frequencies_by(stalled, & &1.onboarding_state),
      started: MapSet.size(starters),
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

  # The accounts that started something and got nothing back: a conversation
  # row, or a `sandbox_provisioned` usage event for one whose conversation has
  # since been deleted (turns cascade with it, so the metering row is the only
  # surviving witness). This union used to *be* the activated stage; it is
  # honest here, one stage below the reply it never produced.
  defp started_ids(stalled_ids) do
    ids = MapSet.to_list(stalled_ids)

    conversations =
      Repo.all(
        from c in Conversation, where: c.user_id in ^ids, distinct: true, select: c.user_id
      )

    usage =
      Repo.all(
        from e in UsageEvent,
          where: e.user_id in ^ids and e.event_type == "sandbox_provisioned",
          distinct: true,
          select: e.user_id
      )

    MapSet.new(conversations ++ usage)
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

  # Nearest-rank percentile: the smallest value at or above which `p` of the
  # sample sits. No interpolation — with a handful of accounts an interpolated
  # p90 is a number nobody in the sample experienced.
  defp percentile([], _p), do: nil

  defp percentile(values, p) do
    sorted = Enum.sort(values)
    rank = max(1, ceil(p * length(sorted)))
    Enum.at(sorted, rank - 1)
  end
end
