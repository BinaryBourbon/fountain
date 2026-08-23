defmodule Fountain.Release.BillingPeriodsTest do
  @moduledoc """
  `Fountain.Release.backfill_billing_periods/1` (#1016).

  `users.current_period_start` shipped after every existing subscription had
  been created, so without this pass each account keeps reporting usage over a
  calendar month until its next renewal webhook lands — correct, flagged, and
  still a month of numbers that do not match an invoice.

  Lives in `ee/test` because it only means anything with Stripe, even though
  the task itself sits in core's `Fountain.Release` beside the other eval
  tasks.
  """

  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureIO

  alias Fountain.Accounts.User
  alias Fountain.Release

  defp subscribed(attrs) do
    {:ok, user} =
      insert_verified_user()
      |> User.billing_changeset(Map.merge(%{subscription_status: "active"}, attrs))
      |> Repo.update()

    user
  end

  defp stub_retrieve(sub_id, result) do
    stub(Stripe.Subscription, :retrieve, fn ^sub_id -> result end)
    stub(Stripe.Subscription, :retrieve, fn ^sub_id, _opts -> result end)
  end

  test "a dry run counts the gap and calls nothing" do
    subscribed(%{stripe_subscription_id: "sub_dry"})

    # No Stripe stub at all: a dry run that reached the API would blow up here
    # rather than quietly costing a call per account.
    capture_io(fn ->
      assert {:ok, count} = Release.backfill_billing_periods(dry_run: true)
      assert count >= 1
    end)
  end

  test "records both ends of the period Stripe reports" do
    period_start = ~U[2026-05-20 00:00:00Z]
    period_end = ~U[2026-06-20 00:00:00Z]
    user = subscribed(%{stripe_subscription_id: "sub_backfill_#{System.unique_integer()}"})

    stub_retrieve(
      user.stripe_subscription_id,
      {:ok,
       %Stripe.Subscription{
         id: user.stripe_subscription_id,
         status: "active",
         current_period_start: DateTime.to_unix(period_start),
         current_period_end: DateTime.to_unix(period_end)
       }}
    )

    capture_io(fn -> assert {:ok, _} = Release.backfill_billing_periods() end)

    reloaded = Repo.reload!(user)
    assert reloaded.current_period_start == period_start
    assert reloaded.current_period_end == period_end
  end

  test "leaves status, trial and plan alone" do
    # A bulk repair that quietly flipped account statuses would be a much
    # bigger action than the one an operator asked for. `resync_from_stripe/1`
    # is the function that adopts everything Stripe says.
    period_start = ~U[2026-05-20 00:00:00Z]

    user =
      subscribed(%{
        stripe_subscription_id: "sub_narrow_#{System.unique_integer()}",
        subscription_status: "past_due",
        plan: "team"
      })

    stub_retrieve(
      user.stripe_subscription_id,
      {:ok,
       %Stripe.Subscription{
         id: user.stripe_subscription_id,
         status: "canceled",
         trial_end: DateTime.to_unix(~U[2026-01-01 00:00:00Z]),
         current_period_start: DateTime.to_unix(period_start),
         current_period_end: DateTime.to_unix(~U[2026-06-20 00:00:00Z])
       }}
    )

    capture_io(fn -> assert {:ok, _} = Release.backfill_billing_periods() end)

    reloaded = Repo.reload!(user)
    assert reloaded.current_period_start == period_start
    assert reloaded.subscription_status == "past_due"
    assert reloaded.plan == "team"
    assert reloaded.trial_ends_at == user.trial_ends_at
  end

  test "a subscription Stripe cannot hand back is skipped, not fatal" do
    user = subscribed(%{stripe_subscription_id: "sub_gone_#{System.unique_integer()}"})

    stub_retrieve(
      user.stripe_subscription_id,
      {:error,
       %Stripe.Error{
         source: :stripe,
         code: :resource_missing,
         message: "no such subscription"
       }}
    )

    # Nothing repaired and nothing raised — but the task must not report a
    # clean pass over a run that fixed nothing. One skipped account is a
    # deleted subscription; every account skipped is a bad STRIPE_SECRET_KEY
    # or an unreachable Stripe, and the operator has to hear about it.
    warning =
      capture_io(:stderr, fn ->
        capture_io(fn -> assert {:ok, 0} = Release.backfill_billing_periods() end)
      end)

    assert warning =~ "was skipped"
    assert warning =~ "STRIPE_SECRET_KEY"
    assert is_nil(Repo.reload!(user).current_period_start)
  end

  test "an account that already has a start is not re-read" do
    user =
      subscribed(%{
        stripe_subscription_id: "sub_done_#{System.unique_integer()}",
        current_period_start: ~U[2026-05-20 00:00:00Z],
        current_period_end: ~U[2026-06-20 00:00:00Z]
      })

    # No stub: re-reading it would raise, which is the assertion.
    capture_io(fn -> assert {:ok, _} = Release.backfill_billing_periods() end)

    assert Repo.reload!(user).current_period_start == ~U[2026-05-20 00:00:00Z]
  end
end
