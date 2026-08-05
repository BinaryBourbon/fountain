defmodule Fountain.TrialSweeperTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.{Billing, Repo}
  alias Fountain.Workers.LifecycleEmail

  @now ~U[2026-08-05 12:00:00Z]
  # Comfortably past the 48h grace window relative to @now.
  @long_expired ~U[2026-08-01 12:00:00Z]

  defp trialing_user(attrs) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> User.billing_changeset(Map.merge(%{subscription_status: "trialing"}, attrs))
      |> Repo.update()

    user
  end

  describe "expire_stale_trials/1 — local trials (no Stripe subscription)" do
    test "flips a long-expired trial to canceled and enqueues the trial-expired email" do
      user = trialing_user(%{trial_ends_at: @long_expired})

      assert %{expired: 1, synced: 0, extended: 0, skipped: 0} =
               Billing.expire_stale_trials(now: @now)

      reloaded = Repo.reload(user)
      assert reloaded.subscription_status == "canceled"
      assert DateTime.compare(reloaded.subscription_synced_at, @now) == :eq

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "trial_expired"}
      )
    end

    test "leaves a trial inside the grace window alone" do
      user = trialing_user(%{trial_ends_at: DateTime.add(@now, -3600, :second)})

      assert %{expired: 0, synced: 0, extended: 0, skipped: 0} =
               Billing.expire_stale_trials(now: @now)

      assert Repo.reload(user).subscription_status == "trialing"
    end

    test "leaves nil trial_ends_at rows alone" do
      user = trialing_user(%{trial_ends_at: nil})

      assert %{expired: 0, synced: 0, extended: 0, skipped: 0} =
               Billing.expire_stale_trials(now: @now)

      assert Repo.reload(user).subscription_status == "trialing"
    end

    test "never touches non-trialing statuses" do
      users =
        for status <- ["active", "past_due", "canceled", "comped"] do
          {status, trialing_user(%{subscription_status: status, trial_ends_at: @long_expired})}
        end

      assert %{expired: 0, synced: 0, extended: 0, skipped: 0} =
               Billing.expire_stale_trials(now: @now)

      for {status, user} <- users do
        assert Repo.reload(user).subscription_status == status
      end
    end
  end

  describe "expire_stale_trials/1 — Stripe-backed trials" do
    test "adopts a canceled Stripe status through the lifecycle-email path" do
      user =
        trialing_user(%{trial_ends_at: @long_expired, stripe_subscription_id: "sub_sweep_1"})

      expect(Stripe.Subscription, :retrieve, fn "sub_sweep_1" ->
        {:ok,
         %Stripe.Subscription{
           id: "sub_sweep_1",
           status: "canceled",
           trial_end: DateTime.to_unix(@long_expired)
         }}
      end)

      assert %{expired: 0, synced: 1, extended: 0, skipped: 0} =
               Billing.expire_stale_trials(now: @now)

      reloaded = Repo.reload(user)
      assert reloaded.subscription_status == "canceled"
      assert DateTime.compare(reloaded.subscription_synced_at, @now) == :eq

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "trial_expired"}
      )
    end

    test "repairs the local clock when Stripe says the trial was extended" do
      new_end = DateTime.add(@now, 7 * 24 * 3600, :second)

      user =
        trialing_user(%{trial_ends_at: @long_expired, stripe_subscription_id: "sub_sweep_2"})

      expect(Stripe.Subscription, :retrieve, fn "sub_sweep_2" ->
        {:ok,
         %Stripe.Subscription{
           id: "sub_sweep_2",
           status: "trialing",
           trial_end: DateTime.to_unix(new_end)
         }}
      end)

      assert %{expired: 0, synced: 0, extended: 1, skipped: 0} =
               Billing.expire_stale_trials(now: @now)

      reloaded = Repo.reload(user)
      assert reloaded.subscription_status == "trialing"
      assert DateTime.compare(reloaded.trial_ends_at, new_end) == :eq

      refute_enqueued(worker: LifecycleEmail)
    end

    test "skips the row when Stripe is unreachable, leaving it for the next run" do
      user =
        trialing_user(%{trial_ends_at: @long_expired, stripe_subscription_id: "sub_sweep_3"})

      expect(Stripe.Subscription, :retrieve, fn "sub_sweep_3" -> {:error, :stripe_down} end)

      assert %{expired: 0, synced: 0, extended: 0, skipped: 1} =
               Billing.expire_stale_trials(now: @now)

      assert Repo.reload(user).subscription_status == "trialing"
      refute_enqueued(worker: LifecycleEmail)
    end
  end

  describe "TrialSweeper worker" do
    test "sweeps via perform/1" do
      user = trialing_user(%{trial_ends_at: @long_expired})

      assert :ok = perform_job(Fountain.Workers.TrialSweeper, %{})

      assert Repo.reload(user).subscription_status == "canceled"
    end
  end
end
