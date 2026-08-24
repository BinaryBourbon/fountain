defmodule Fountain.Workers.CreditGranter do
  @moduledoc """
  Puts the free money in, and takes the unused free money back out (ADR 0030
  decision 2).

  Three passes, all idempotent, all no-ops until `credits.pricing_since` is
  set and billing is on:

    * **Tier grant.** Every subscriber whose subscription names a billing
      period gets `Plans.included_turn_hours × turn-hour price` once per
      period, under `grant_tier:<user_id>:<period_start>`, expiring at the
      period's end. Solo 40 h → $10, Team 100 h → $25, Scale 200 h → $50.
      A period that began before `pricing_since` is pro-rated to the part
      that falls after it, so the switch never grants a month that was
      already mostly spent unmetered (#1086 phase 5).
    * **Trial grant.** A trialing account gets the trial plan's hours once,
      ever, under `grant_trial:<user_id>`, expiring when the trial ends.
    * **Expiry.** A grant whose `expires_at` has passed loses whatever of it
      is unspent, under `expire:<grant_id>`. Burn order is granted first,
      oldest expiry first, then purchased (see `unspent_of/2`), so a
      customer never loses paid money while free money sat unused.

  Comped accounts get no grant: nothing is enforced on them and a grant
  would only inflate the deferred-balance liability `Finance` reports.

  Daily is late by up to a day at a renewal. `grant_for_user/2` is the
  same pass for one tenant, for the webhook to call when a period changes
  (#1086 phase 4) and for phase 5's release task.
  """

  use Oban.Worker, queue: :billing, max_attempts: 3, unique: [period: 60]

  import Ecto.Query

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Credits.LedgerEntry
  alias Fountain.Plans
  alias Fountain.Repo

  require Logger

  @batch 500

  @impl Oban.Worker
  def perform(_job) do
    case run() do
      %{tier: 0, trial: 0, expired: 0} ->
        :ok

      c ->
        Logger.info(
          "credit granter: #{c.tier} tier grants, #{c.trial} trial grants, #{c.expired} expiries"
        )
    end

    :ok
  end

  @doc """
  Run all three passes now. `:now` pins the clock; `:since` overrides the
  configured floor. Counts rows written.
  """
  @spec run(keyword()) :: %{
          tier: non_neg_integer(),
          trial: non_neg_integer(),
          expired: non_neg_integer()
        }
  def run(opts \\ []) do
    since = Keyword.get(opts, :since) || Fountain.Workers.CreditPricer.pricing_since()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    cond do
      not Billing.enabled?() ->
        %{tier: 0, trial: 0, expired: 0}

      is_nil(since) ->
        %{tier: 0, trial: 0, expired: 0}

      true ->
        %{
          tier: grant_tiers(since, now),
          trial: grant_trials(since, now),
          expired: expire_grants(now)
        }
    end
  end

  @doc """
  The tier and trial passes for one tenant. Returns the rows written, `0..2`.
  Same floor rules as `run/1`.
  """
  @spec grant_for_user(User.t(), keyword()) :: non_neg_integer()
  def grant_for_user(%User{} = user, opts \\ []) do
    since = Keyword.get(opts, :since) || Fountain.Workers.CreditPricer.pricing_since()
    now = Keyword.get(opts, :now) || DateTime.utc_now()

    if Billing.enabled?() and not is_nil(since) do
      Enum.count([tier_grant(user, since, now), trial_grant(user, since, now)], & &1)
    else
      0
    end
  end

  # ---------------------------------------------------------------------------
  # Tier grants
  # ---------------------------------------------------------------------------

  defp grant_tiers(since, now) do
    from(u in User,
      where: u.subscription_status == "active",
      where: not is_nil(u.current_period_start) and not is_nil(u.current_period_end),
      where: u.current_period_start <= ^now and u.current_period_end > ^now,
      left_join: l in LedgerEntry,
      on:
        l.idempotency_key ==
          fragment("'grant_tier:' || ?::text || ':' || ?::text", u.id, u.current_period_start),
      where: is_nil(l.id),
      limit: @batch
    )
    |> Repo.all()
    |> Enum.count(&tier_grant(&1, since, now))
  end

  defp tier_grant(
         %User{
           subscription_status: "active",
           current_period_start: %DateTime{} = ps,
           current_period_end: %DateTime{} = pe
         } = user,
         since,
         now
       ) do
    in_period? = DateTime.compare(ps, now) != :gt and DateTime.compare(pe, now) == :gt
    hours = Plans.included_turn_hours(user)
    cents = prorate(hours * Credits.price_card().turn_hour, ps, pe, since)

    if in_period? and cents > 0 do
      key = "grant_tier:#{user.id}:#{DateTime.to_iso8601(ps)}"
      # `to_iso8601` on a second-truncated value matches Postgres's `::text`
      # only for the anti-join's purposes if both sides normalise the same
      # way; the key is built here, in Elixir, on both the grant and the
      # lookup path, so the fragment above is a fast filter and this is the
      # decider.
      grant(user, cents, "grant_tier", key,
        expires_at: pe,
        resource_type: "billing_period",
        resource_id: DateTime.to_iso8601(ps),
        metadata: %{"plan" => Plans.resolve(user).slug, "hours" => hours}
      )
    else
      false
    end
  end

  defp tier_grant(_user, _since, _now), do: false

  # Whole cents of `cents` for the part of [ps, pe) that falls at or after
  # `since`; the whole amount when the period started after the switch.
  defp prorate(cents, ps, pe, since) do
    if DateTime.compare(since, ps) != :gt do
      cents
    else
      total = DateTime.diff(pe, ps, :second)
      left = DateTime.diff(pe, since, :second)
      if total <= 0 or left <= 0, do: 0, else: div(cents * left + div(total, 2), total)
    end
  end

  # ---------------------------------------------------------------------------
  # Trial grants
  # ---------------------------------------------------------------------------

  defp grant_trials(since, now) do
    from(u in User,
      where: u.subscription_status == "trialing",
      where: not is_nil(u.trial_ends_at) and u.trial_ends_at > ^now,
      left_join: l in LedgerEntry,
      on: l.idempotency_key == fragment("'grant_trial:' || ?::text", u.id),
      where: is_nil(l.id),
      limit: @batch
    )
    |> Repo.all()
    |> Enum.count(&trial_grant(&1, since, now))
  end

  defp trial_grant(
         %User{subscription_status: "trialing", trial_ends_at: %DateTime{} = ends} = user,
         _since,
         now
       ) do
    hours = Plans.fetch!("trial").included_turn_hours
    cents = hours * Credits.price_card().turn_hour

    if DateTime.compare(ends, now) == :gt and cents > 0 do
      grant(user, cents, "grant_trial", "grant_trial:#{user.id}",
        expires_at: ends,
        resource_type: "trial",
        resource_id: user.id,
        metadata: %{"hours" => hours}
      )
    else
      false
    end
  end

  defp trial_grant(_user, _since, _now), do: false

  defp grant(user, cents, reason, key, opts) do
    case Credits.grant(
           user.id,
           cents,
           reason,
           [idempotency_key: key, actor: "system:credit_granter"] ++ opts
         ) do
      {:ok, _} ->
        true

      {:ok, :duplicate, _} ->
        false

      {:error, why} ->
        Logger.warning("credit granter: #{reason} for #{user.id} not written: #{inspect(why)}")
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Expiry
  # ---------------------------------------------------------------------------

  defp expire_grants(now) do
    from(g in LedgerEntry,
      where: g.amount_cents > 0 and not is_nil(g.expires_at) and g.expires_at <= ^now,
      left_join: x in LedgerEntry,
      on: x.idempotency_key == fragment("'expire:' || ?::text", g.id),
      where: is_nil(x.id),
      order_by: [asc: g.expires_at],
      limit: @batch
    )
    |> Repo.all()
    |> Enum.count(&expire_grant/1)
  end

  # Zero unspent is still "handled": a zero-amount row is invalid, so the
  # grant would be re-examined every run. Mark it with a no-op-sized row?
  # No — instead the anti-join stays and the cost is one row per fully-spent
  # grant per run, bounded by how many grants a tenant has ever had. Cheap.
  defp expire_grant(%LedgerEntry{} = grant) do
    case Credits.unspent_of(grant, Credits.balance(grant.user_id)) do
      0 ->
        false

      cents ->
        case Credits.debit(grant.user_id, cents, "expire",
               idempotency_key: "expire:#{grant.id}",
               resource_type: "credit_ledger",
               resource_id: grant.id,
               actor: "system:credit_granter",
               metadata: %{"grant_reason" => grant.reason, "granted_cents" => grant.amount_cents}
             ) do
          {:ok, _} ->
            true

          {:ok, :duplicate, _} ->
            false

          {:error, why} ->
            Logger.warning("credit granter: expire #{grant.id} failed: #{inspect(why)}")
            false
        end
    end
  end

  @doc "See `Fountain.Credits.unspent_of/2`; kept here for the tests that grew up with it."
  @spec unspent_of(LedgerEntry.t(), integer()) :: non_neg_integer()
  def unspent_of(%LedgerEntry{} = grant, balance), do: Credits.unspent_of(grant, balance)
end
