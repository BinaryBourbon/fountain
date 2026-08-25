defmodule Fountain.Workers.CreditGranterTest do
  @moduledoc """
  Grants land once per period and once per trial, pro-rate across the
  switch, and expire under the granted-first, oldest-first, then-purchased
  burn order.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Repo
  alias Fountain.Workers.CreditGranter

  @ps ~U[2026-08-01 00:00:00Z]
  @pe ~U[2026-09-01 00:00:00Z]
  @now ~U[2026-08-10 12:00:00Z]
  @since ~U[2026-07-01 00:00:00Z]

  defp subscriber(plan, attrs \\ %{}) do
    user = insert_active_user()

    {:ok, user} =
      user
      |> User.billing_changeset(
        Map.merge(%{plan: plan, current_period_start: @ps, current_period_end: @pe}, attrs)
      )
      |> Repo.update()

    user
  end

  defp trialer(ends) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> User.billing_changeset(%{subscription_status: "trialing", trial_ends_at: ends})
      |> Repo.update()

    user
  end

  test "no-ops with no floor and with billing off" do
    subscriber("solo")
    assert %{tier: 0, trial: 0, expired: 0} = CreditGranter.run(now: @now)

    Application.put_env(:fountain, :billing_enabled, false)
    on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)
    assert %{tier: 0, trial: 0, expired: 0} = CreditGranter.run(since: @since, now: @now)
  end

  describe "tier grants" do
    test "each plan gets its hours at the turn-hour price, once per period, expiring at period end" do
      solo = subscriber("solo")
      team = subscriber("team")
      scale = subscriber("scale")
      legacy = subscriber("legacy")

      assert %{tier: 4} = CreditGranter.run(since: @since, now: @now)
      assert Credits.balance(solo.id) == 1000
      assert Credits.balance(team.id) == 2500
      assert Credits.balance(scale.id) == 5000
      assert Credits.balance(legacy.id) == 2500

      [entry] = Credits.list_entries(solo.id)
      assert entry.reason == "grant_tier"
      assert entry.expires_at == @pe
      assert entry.idempotency_key == "grant_tier:#{solo.id}:#{DateTime.to_iso8601(@ps)}"
      assert entry.metadata == %{"plan" => "solo"}

      assert %{tier: 0} = CreditGranter.run(since: @since, now: @now)
      assert Credits.balance(solo.id) == 1000
    end

    test "a new period is a new grant" do
      user = subscriber("solo")
      assert %{tier: 1} = CreditGranter.run(since: @since, now: @now)

      {:ok, _} =
        user
        |> User.billing_changeset(%{
          current_period_start: @pe,
          current_period_end: ~U[2026-10-01 00:00:00Z]
        })
        |> Repo.update()

      # The old period's grant expires in the same sweep, unspent.
      assert %{tier: 1, expired: 1} =
               CreditGranter.run(since: @since, now: ~U[2026-09-02 00:00:00Z])

      assert Credits.balance(user.id) == 1000

      assert Enum.map(Credits.list_entries(user.id), & &1.reason) |> Enum.sort() ==
               ~w(expire grant_tier grant_tier)
    end

    test "a period that began before the switch is pro-rated to the part after it" do
      user = subscriber("solo")
      # Switch on at the 16th: 16 of 31 days remain.
      since = ~U[2026-08-16 00:00:00Z]
      assert %{tier: 1} = CreditGranter.run(since: since, now: ~U[2026-08-16 06:00:00Z])
      assert Credits.balance(user.id) == div(1000 * 16 + 15, 31)
    end

    test "no grant outside the period, for comped, canceled, trialing or period-less accounts" do
      subscriber("solo", %{
        current_period_start: ~U[2026-06-01 00:00:00Z],
        current_period_end: ~U[2026-07-01 00:00:00Z]
      })

      comped = subscriber("solo")
      {:ok, _} = Billing.comp_account(comped)
      subscriber("solo", %{subscription_status: "canceled"})
      subscriber("solo", %{subscription_status: "trialing", trial_ends_at: nil})

      no_period = insert_active_user()
      {:ok, _} = no_period |> User.billing_changeset(%{plan: "solo"}) |> Repo.update()

      assert %{tier: 0, trial: 0} = CreditGranter.run(since: @since, now: @now)
    end
  end

  describe "trial grants" do
    test "a live trial gets the trial plan's hours once, expiring with the trial" do
      ends = ~U[2026-08-20 00:00:00Z]
      user = trialer(ends)

      assert %{trial: 1} = CreditGranter.run(since: @since, now: @now)
      assert Credits.balance(user.id) == 1000
      [entry] = Credits.list_entries(user.id)
      assert entry.reason == "grant_trial"
      assert entry.expires_at == ends

      assert %{trial: 0} = CreditGranter.run(since: @since, now: @now)
    end

    test "an expired or open-ended trial gets nothing" do
      trialer(~U[2026-08-01 00:00:00Z])
      trialer(nil)
      assert %{trial: 0} = CreditGranter.run(since: @since, now: @now)
    end
  end

  describe "grant_for_user/2" do
    test "does both passes for one tenant" do
      user = subscriber("team")
      assert 1 = CreditGranter.grant_for_user(user, since: @since, now: @now)
      assert 0 = CreditGranter.grant_for_user(user, since: @since, now: @now)
      assert Credits.balance(user.id) == 2500
    end
  end

  describe "expiry" do
    test "an unspent grant expires in full; a spent one expires nothing" do
      full = subscriber("solo")
      spent = subscriber("solo")
      assert %{tier: 2} = CreditGranter.run(since: @since, now: @now)
      {:ok, _} = Credits.debit(spent.id, 1000, "burn_turn", idempotency_key: "spent-all")

      assert %{expired: 1} = CreditGranter.run(since: @since, now: ~U[2026-09-01 00:00:01Z])
      assert Credits.balance(full.id) == 0
      assert Credits.balance(spent.id) == 0

      x = Credits.list_entries(full.id) |> Enum.find(&(&1.reason == "expire"))
      assert x.amount_cents == -1000
      assert x.metadata["granted_cents"] == 1000

      # A second sweep writes nothing.
      assert %{expired: 0} = CreditGranter.run(since: @since, now: ~U[2026-09-02 00:00:00Z])
    end

    test "purchased money survives an expiry; only the granted remainder goes" do
      user = subscriber("solo")
      assert %{tier: 1} = CreditGranter.run(since: @since, now: @now)
      {:ok, _} = Credits.grant(user.id, 2500, "purchase", idempotency_key: "buy")
      # 3500 total; burn 600, which comes out of the grant first.
      {:ok, _} = Credits.debit(user.id, 600, "burn_turn", idempotency_key: "b")

      assert %{expired: 1} = CreditGranter.run(since: @since, now: ~U[2026-09-01 00:00:01Z])
      # 400 of the grant was unspent and is gone; the 2500 purchase stays.
      assert Credits.balance(user.id) == 2500
    end

    test "a clawback reduces what counts as purchased" do
      user = subscriber("solo")
      assert %{tier: 1} = CreditGranter.run(since: @since, now: @now)
      {:ok, bought} = Credits.grant(user.id, 2500, "purchase", idempotency_key: "buy")
      # A clawback names its purchase lot, as Purchases does.
      {:ok, _} =
        Credits.debit(user.id, 2500, "clawback_refund",
          idempotency_key: "refund",
          lot_id: bought.id
        )

      # Balance 1000, all of it grant.
      assert %{expired: 1} = CreditGranter.run(since: @since, now: ~U[2026-09-01 00:00:01Z])
      assert Credits.balance(user.id) == 0
    end

    test "burns consume the earliest-expiring grant first" do
      user = insert_active_user()

      {:ok, a} =
        Credits.grant(user.id, 1000, "grant_admin",
          idempotency_key: "a",
          expires_at: ~U[2026-09-01 00:00:00Z]
        )

      {:ok, b} =
        Credits.grant(user.id, 1000, "grant_admin",
          idempotency_key: "b",
          expires_at: ~U[2026-10-01 00:00:00Z]
        )

      {:ok, _} = Credits.debit(user.id, 1500, "burn_turn", idempotency_key: "burn")
      # 500 left: A is fully consumed, B has 500.
      assert CreditGranter.unspent_of(a, 500) == 0
      assert CreditGranter.unspent_of(b, 500) == 500

      assert %{expired: 0} = CreditGranter.run(since: @since, now: ~U[2026-09-01 00:00:01Z])
      assert Credits.balance(user.id) == 500
      assert %{expired: 1} = CreditGranter.run(since: @since, now: ~U[2026-10-01 00:00:01Z])
      assert Credits.balance(user.id) == 0
    end

    test "a negative balance has nothing to expire" do
      user = subscriber("solo")
      assert %{tier: 1} = CreditGranter.run(since: @since, now: @now)
      {:ok, _} = Credits.debit(user.id, 1200, "burn_turn", idempotency_key: "over")
      assert %{expired: 0} = CreditGranter.run(since: @since, now: ~U[2026-09-01 00:00:01Z])
      assert Credits.balance(user.id) == -200
    end
  end

  test "perform/1 is a thin shell over run/1" do
    assert :ok = CreditGranter.perform(%Oban.Job{args: %{}})
  end
end
