defmodule Fountain.BillingTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Billing
  alias Fountain.Billing.UsageEvent
  alias Fountain.Repo

  describe "assert_active!/1" do
    test "returns :ok for trialing status" do
      user = user_with_status("trialing")
      assert :ok = Billing.assert_active!(user)
    end

    test "returns :ok for active status" do
      user = user_with_status("active")
      assert :ok = Billing.assert_active!(user)
    end

    test "raises SubscriptionRequiredError for past_due status" do
      user = user_with_status("past_due")

      assert_raise Billing.SubscriptionRequiredError, fn ->
        Billing.assert_active!(user)
      end
    end

    test "raises SubscriptionRequiredError for canceled status" do
      user = user_with_status("canceled")

      assert_raise Billing.SubscriptionRequiredError, fn ->
        Billing.assert_active!(user)
      end
    end
  end

  describe "usage_summary/3" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "returns zeros when no events exist", %{user: user} do
      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 0
      assert summary.turns == 0
      assert summary.sandbox_minutes == 0.0
    end

    test "counts sandbox_provisioned events as conversations", %{user: user} do
      insert_event(user, "sandbox_provisioned", ~U[2026-05-10 12:00:00Z])
      insert_event(user, "sandbox_provisioned", ~U[2026-05-15 09:00:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 2
      assert summary.turns == 0
    end

    test "counts sandbox_provision_failed events as conversations too", %{user: user} do
      insert_event(user, "sandbox_provisioned", ~U[2026-05-10 12:00:00Z])
      insert_event(user, "sandbox_provision_failed", ~U[2026-05-11 12:00:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 2
    end

    test "counts turn_started events as turns", %{user: user} do
      insert_event(user, "turn_started", ~U[2026-05-10 12:00:00Z])
      insert_event(user, "turn_started", ~U[2026-05-10 12:05:00Z])
      insert_event(user, "turn_started", ~U[2026-05-10 12:10:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.turns == 3
    end

    test "sums duration_ms from sandbox_terminated events into sandbox_minutes", %{user: user} do
      # 60_000 ms = 1 min, 120_000 ms = 2 min -> total 3.0 minutes
      insert_event(user, "sandbox_terminated", ~U[2026-05-10 12:00:00Z], %{
        "duration_ms" => 60_000
      })

      insert_event(user, "sandbox_terminated", ~U[2026-05-10 12:30:00Z], %{
        "duration_ms" => 120_000
      })

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 3.0
    end

    test "excludes events outside the period", %{user: user} do
      # One second before period start - excluded
      insert_event(user, "turn_started", ~U[2026-04-30 23:59:59Z])
      # Exactly at period_end - excluded (query uses `< ^period_end`)
      insert_event(user, "sandbox_provisioned", ~U[2026-06-01 00:00:00Z])

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.conversations == 0
      assert summary.turns == 0
      assert summary.sandbox_minutes == 0.0
    end
  end

  describe "emit/5" do
    setup do
      {:ok, user: insert_verified_user()}
    end

    test "inserts a UsageEvent and returns {:ok, event} with correct fields", %{user: user} do
      resource_id = Ecto.UUID.generate()

      assert {:ok, event} =
               Billing.emit(user.id, "sandbox_provisioned", resource_id, "sandbox", %{
                 "foo" => "bar"
               })

      assert event.user_id == user.id
      assert event.event_type == "sandbox_provisioned"
      assert event.resource_id == resource_id
      assert event.resource_type == "sandbox"
      assert event.metadata == %{"foo" => "bar"}
      assert event.id != nil
    end

    test "metadata defaults to %{} when called with arity 4", %{user: user} do
      resource_id = Ecto.UUID.generate()

      assert {:ok, event} = Billing.emit(user.id, "turn_started", resource_id, "conversation")

      assert event.metadata == %{}
    end

    test "emitted event is queryable from the DB", %{user: user} do
      assert {:ok, event} =
               Billing.emit(user.id, "sandbox_terminated", nil, nil, %{"duration_ms" => 30_000})

      persisted = Repo.get!(UsageEvent, event.id)
      assert persisted.user_id == user.id
      assert persisted.event_type == "sandbox_terminated"
      assert persisted.metadata == %{"duration_ms" => 30_000}
    end

    test "raises Ecto.ConstraintError when user_id does not exist (FK constraint)" do
      nonexistent_user_id = Ecto.UUID.generate()

      assert_raise Ecto.ConstraintError, ~r/usage_events_user_id_fkey/, fn ->
        Billing.emit(nonexistent_user_id, "sandbox_provisioned", nil, nil)
      end
    end
  end

  describe "sync_subscription/1" do
    setup do
      user = insert_verified_user()
      user = Repo.update!(Ecto.Changeset.change(user, stripe_customer_id: "cus_abc123"))
      {:ok, user: user}
    end

    test "customer.subscription.updated with matching customer_id updates subscription_status to active",
         %{user: user} do
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_abc123", status: "active", trial_end: nil}}
      }

      assert {:ok, updated_user} = Billing.sync_subscription(event)
      assert updated_user.id == user.id
      assert updated_user.subscription_status == "active"
    end

    test "customer.subscription.deleted sets status to canceled regardless of sub.status",
         %{user: _user} do
      event = %Stripe.Event{
        type: "customer.subscription.deleted",
        data: %{object: %{customer: "cus_abc123", status: "active", trial_end: nil}}
      }

      assert {:ok, updated_user} = Billing.sync_subscription(event)
      assert updated_user.subscription_status == "canceled"
    end

    test "customer.subscription.created with trialing status and trial_end sets status and trial_ends_at",
         %{user: _user} do
      unix_ts = 1_800_000_000
      expected_dt = DateTime.from_unix!(unix_ts) |> DateTime.truncate(:second)

      event = %Stripe.Event{
        type: "customer.subscription.created",
        data: %{object: %{customer: "cus_abc123", status: "trialing", trial_end: unix_ts}}
      }

      assert {:ok, updated_user} = Billing.sync_subscription(event)
      assert updated_user.subscription_status == "trialing"
      assert updated_user.trial_ends_at == expected_dt
    end

    test "unrecognized customer_id returns {:error, :user_not_found}" do
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_unknown999", status: "active", trial_end: nil}}
      }

      assert {:error, :user_not_found} = Billing.sync_subscription(event)
    end

    test "unknown event type returns {:ok, :ignored}" do
      event = %Stripe.Event{
        type: "invoice.payment_succeeded",
        data: %{object: %{}}
      }

      assert {:ok, :ignored} = Billing.sync_subscription(event)
    end

    test "status coercion: past_due -> past_due, canceled -> canceled",
         %{user: _user} do
      for {stripe_status, expected_status} <- [
            {"past_due", "past_due"},
            {"canceled", "canceled"}
          ] do
        event = %Stripe.Event{
          type: "customer.subscription.updated",
          data: %{object: %{customer: "cus_abc123", status: stripe_status, trial_end: nil}}
        }

        assert {:ok, updated_user} = Billing.sync_subscription(event)

        assert updated_user.subscription_status == expected_status,
               "expected #{stripe_status} -> #{expected_status}, got #{updated_user.subscription_status}"
      end
    end

    test "status coercion: unpaid -> past_due, incomplete -> past_due, incomplete_expired -> canceled, paused -> past_due",
         %{user: _user} do
      for {stripe_status, expected_status} <- [
            {"unpaid", "past_due"},
            {"incomplete", "past_due"},
            {"incomplete_expired", "canceled"},
            {"paused", "past_due"}
          ] do
        event = %Stripe.Event{
          type: "customer.subscription.updated",
          data: %{object: %{customer: "cus_abc123", status: stripe_status, trial_end: nil}}
        }

        assert {:ok, updated_user} = Billing.sync_subscription(event)

        assert updated_user.subscription_status == expected_status,
               "expected #{stripe_status} -> #{expected_status}, got #{updated_user.subscription_status}"
      end
    end

    test "extract_customer_id works with expanded customer object %{id: customer_id}",
         %{user: _user} do
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: %{id: "cus_abc123"}, status: "active", trial_end: nil}}
      }

      assert {:ok, updated_user} = Billing.sync_subscription(event)
      assert updated_user.subscription_status == "active"
    end
  end

  describe "sync_subscription/1 — cancel at period end" do
    setup do
      user = insert_verified_user()

      user =
        Repo.update!(
          Ecto.Changeset.change(user,
            stripe_customer_id: "cus_cap",
            subscription_status: "active"
          )
        )

      {:ok, user: user}
    end

    test "a portal cancellation keeps the account active until period end", %{user: _user} do
      period_end = 1_800_000_000

      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{
          object: %{
            customer: "cus_cap",
            status: "active",
            trial_end: nil,
            cancel_at_period_end: true,
            current_period_end: period_end
          }
        }
      }

      assert {:ok, updated} = Billing.sync_subscription(event)

      # The webhook must not hard-lock the account: Stripe keeps the
      # subscription "active" until the period ends, and so do we.
      assert updated.subscription_status == "active"
      assert Billing.check_active(updated) == :ok

      # ...but the pending cancellation and its date are recorded for the UI.
      assert updated.cancel_at_period_end
      assert updated.current_period_end == DateTime.from_unix!(period_end)
    end

    test "renewing from the portal clears the pending cancellation", %{user: user} do
      Repo.update!(Ecto.Changeset.change(user, cancel_at_period_end: true))

      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{
          object: %{
            customer: "cus_cap",
            status: "active",
            trial_end: nil,
            cancel_at_period_end: false,
            current_period_end: 1_800_000_000
          }
        }
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      assert updated.subscription_status == "active"
      refute updated.cancel_at_period_end
    end

    test "subscription.deleted locks the account and clears the pending flag", %{user: user} do
      Repo.update!(Ecto.Changeset.change(user, cancel_at_period_end: true))

      # Stripe's .deleted payload still carries cancel_at_period_end: true from
      # the portal cancellation. It must not survive: a resubscription would
      # otherwise show as "set to cancel" forever.
      event = %Stripe.Event{
        type: "customer.subscription.deleted",
        data: %{
          object: %{
            customer: "cus_cap",
            status: "canceled",
            trial_end: nil,
            cancel_at_period_end: true
          }
        }
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      assert updated.subscription_status == "canceled"
      refute updated.cancel_at_period_end
      assert {:error, :subscription_required} = Billing.check_active(updated)
    end

    test "events without the field (older payload shapes) default to false", %{user: _user} do
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_cap", status: "active", trial_end: nil}}
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      refute updated.cancel_at_period_end
      assert updated.current_period_end == nil
    end
  end

  describe "sync_subscription/1 — the return path for canceled" do
    test "a canceled account that buys again is re-activated by the webhook" do
      user = insert_verified_user()

      user =
        Repo.update!(
          Ecto.Changeset.change(user,
            stripe_customer_id: "cus_return",
            subscription_status: "canceled"
          )
        )

      assert {:error, :subscription_required} = Billing.check_active(user)

      # Checkout completed -> Stripe opens a fresh subscription and sends this.
      event = %Stripe.Event{
        type: "customer.subscription.created",
        data: %{object: %{customer: "cus_return", status: "active", trial_end: nil}}
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      assert updated.id == user.id
      assert updated.subscription_status == "active"
      assert Billing.check_active(updated) == :ok
    end
  end

  describe "has_live_subscription?/1" do
    test "false without a Stripe customer — nothing to duplicate" do
      assert {:ok, false} = Billing.has_live_subscription?(insert_verified_user())
    end

    test "true when a subscription canceled at period end is still live" do
      user = user_with_customer("cus_live_cap")

      stub(Stripe.Subscription, :list, fn %{customer: "cus_live_cap", status: :all} ->
        # cancel_at_period_end keeps the Stripe status "active" until the
        # period ends — exactly the subscription Checkout would duplicate.
        {:ok,
         %{
           data: [
             %Stripe.Subscription{id: "sub_cap", status: "active", cancel_at_period_end: true}
           ],
           has_more: false
         }}
      end)

      assert {:ok, true} = Billing.has_live_subscription?(user)
    end

    test "false when every subscription is terminal" do
      user = user_with_customer("cus_all_dead")

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok,
         %{
           data: [
             %Stripe.Subscription{id: "sub_c", status: "canceled"},
             %Stripe.Subscription{id: "sub_ie", status: "incomplete_expired"}
           ],
           has_more: false
         }}
      end)

      assert {:ok, false} = Billing.has_live_subscription?(user)
    end

    test "a Stripe failure is reported, not guessed at" do
      user = user_with_customer("cus_down")
      stub(Stripe.Subscription, :list, fn _ -> {:error, :stripe_down} end)

      assert {:error, :stripe_down} = Billing.has_live_subscription?(user)
    end
  end

  describe "create_stripe_customer/1" do
    test "on Stripe success: stores stripe_customer_id on user and sets trial_ends_at ~14 days from now" do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _attrs ->
        {:ok, %Stripe.Customer{id: "cus_new123"}}
      end)

      assert {:ok, updated_user} = Billing.create_stripe_customer(user)
      assert updated_user.stripe_customer_id == "cus_new123"
      assert %DateTime{} = updated_user.trial_ends_at

      expected_lower = DateTime.utc_now() |> DateTime.add(13 * 24 * 60 * 60, :second)
      expected_upper = DateTime.utc_now() |> DateTime.add(15 * 24 * 60 * 60, :second)

      assert DateTime.compare(updated_user.trial_ends_at, expected_lower) in [:gt, :eq]
      assert DateTime.compare(updated_user.trial_ends_at, expected_upper) in [:lt, :eq]
    end

    test "on Stripe error: returns {:error, reason} without modifying the user" do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _attrs ->
        {:error, %Stripe.Error{message: "card declined", source: :stripe, code: :card_declined}}
      end)

      assert {:error, %Stripe.Error{}} = Billing.create_stripe_customer(user)

      unchanged = Repo.get!(Fountain.Accounts.User, user.id)
      assert unchanged.stripe_customer_id == nil
    end
  end

  describe "usage_summary/3 — sandbox_minutes edge cases" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "sandbox_minutes defaults to 0 when duration_ms key is absent from metadata", %{
      user: user
    } do
      insert_event(user, "sandbox_terminated", ~U[2026-05-10 12:00:00Z], %{})

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 0.0
    end

    test "sandbox_minutes handles mixed events where some lack duration_ms", %{user: user} do
      insert_event(user, "sandbox_terminated", ~U[2026-05-10 12:00:00Z], %{
        "duration_ms" => 60_000
      })

      insert_event(user, "sandbox_terminated", ~U[2026-05-11 12:00:00Z], %{})

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      # Only the first event contributes 1 minute; the second defaults to 0
      assert summary.sandbox_minutes == 1.0
    end
  end

  describe "usage_summary/3 — suspend-aware sandbox_minutes (#665)" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]
    @sandbox_id Ecto.UUID.generate()

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "subtracts a closed suspend/resume interval from the terminated duration", %{
      user: user
    } do
      # Alive 12:00 -> 13:00 (1h = 3_600_000ms), parked 12:20 -> 12:50 (30min).
      # Net run time: 30 minutes.
      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, @sandbox_id)
      insert_event(user, "sandbox_resumed", ~U[2026-05-10 12:50:00Z], %{}, @sandbox_id)

      insert_event(
        user,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 3_600_000},
        @sandbox_id
      )

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 30.0
    end

    test "closes a dangling suspend against the terminated event itself", %{user: user} do
      # A sandbox that parks and is torn down (account deletion, tenant reap)
      # without ever waking again: no sandbox_resumed at all. The whole parked
      # span (12:20 -> 13:00, 40 minutes) must come off the hour.
      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, @sandbox_id)

      insert_event(
        user,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 3_600_000},
        @sandbox_id
      )

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 20.0
    end

    test "sums multiple park cycles on the same sandbox", %{user: user} do
      # Two separate suspend/resume cycles of 10 minutes each = 20 minutes
      # parked out of the hour.
      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:10:00Z], %{}, @sandbox_id)
      insert_event(user, "sandbox_resumed", ~U[2026-05-10 12:20:00Z], %{}, @sandbox_id)
      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:40:00Z], %{}, @sandbox_id)
      insert_event(user, "sandbox_resumed", ~U[2026-05-10 12:50:00Z], %{}, @sandbox_id)

      insert_event(
        user,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 3_600_000},
        @sandbox_id
      )

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 40.0
    end

    test "never goes negative when parked time would exceed the recorded duration", %{
      user: user
    } do
      insert_event(user, "sandbox_suspended", ~U[2026-05-10 11:00:00Z], %{}, @sandbox_id)

      insert_event(
        user,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 60_000},
        @sandbox_id
      )

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 0.0
    end

    test "keys parked intervals per sandbox — one sandbox's suspend does not bleed into another's",
         %{user: user} do
      other_sandbox_id = Ecto.UUID.generate()

      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, other_sandbox_id)
      insert_event(user, "sandbox_resumed", ~U[2026-05-10 12:50:00Z], %{}, other_sandbox_id)

      insert_event(
        user,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 3_600_000},
        @sandbox_id
      )

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      # The suspend/resume pair belongs to a different sandbox; the terminated
      # sandbox's full hour still counts.
      assert summary.sandbox_minutes == 60.0
    end

    test "a suspend still parked at period end (no resume, no terminated event) contributes nothing",
         %{user: user} do
      insert_event(user, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, @sandbox_id)

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      assert summary.sandbox_minutes == 0.0
    end
  end

  describe "sync_subscription/1 — trial_end nil branch" do
    setup do
      user = insert_verified_user()
      user = Repo.update!(Ecto.Changeset.change(user, stripe_customer_id: "cus_trial_nil"))
      {:ok, user: user}
    end

    test "sets trial_ends_at to nil when trial_end is nil in the event", %{user: _user} do
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_trial_nil", status: "active", trial_end: nil}}
      }

      assert {:ok, updated_user} = Billing.sync_subscription(event)
      assert updated_user.trial_ends_at == nil
    end
  end

  describe "sync_subscription/1 — extract_customer_id nil branch" do
    test "returns {:error, :user_not_found} when customer resolves to nil" do
      # Pass an unrecognized map that doesn't match %{id: _}; extract_customer_id
      # falls through to the catch-all clause returning nil, which then hits
      # get_user_by_stripe_customer_id(nil) -> nil -> {:error, :user_not_found}
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: %{}, status: "active", trial_end: nil}}
      }

      assert {:error, :user_not_found} = Billing.sync_subscription(event)
    end
  end

  describe "usage_summary/3 — atom-key duration_ms metadata" do
    @period_start ~U[2026-05-01 00:00:00Z]
    @period_end ~U[2026-06-01 00:00:00Z]

    setup do
      {:ok, user: insert_verified_user()}
    end

    test "reads duration_ms from atom-keyed metadata when string key is absent", %{user: user} do
      # Insert the event directly with atom key in metadata (bypasses Jason decode path)
      %UsageEvent{}
      |> UsageEvent.changeset(%{
        user_id: user.id,
        event_type: "sandbox_terminated",
        inserted_at: ~U[2026-05-10 12:00:00Z],
        metadata: %{duration_ms: 120_000}
      })
      |> Repo.insert!()

      summary = Billing.usage_summary(user.id, @period_start, @period_end)

      # 120_000 ms = 2.0 minutes
      assert summary.sandbox_minutes == 2.0
    end
  end

  describe "resync_from_stripe/1 (#502)" do
    # stripity_stripe's functions carry a default opts arg, and Mimic stubs
    # are arity-specific — stub both arities or the miss silently falls
    # through to the live client (#474).
    defp stub_retrieve(sub_id, result) do
      stub(Stripe.Subscription, :retrieve, fn ^sub_id -> result end)
      stub(Stripe.Subscription, :retrieve, fn ^sub_id, _opts -> result end)
    end

    test "adopts what Stripe says for a drifted account" do
      period_end =
        DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      user =
        billing_state(insert_verified_user(),
          subscription_status: "past_due",
          stripe_customer_id: "cus_resync",
          stripe_subscription_id: "sub_resync"
        )

      stub_retrieve(
        "sub_resync",
        {:ok,
         %Stripe.Subscription{
           id: "sub_resync",
           status: "active",
           trial_end: nil,
           current_period_end: DateTime.to_unix(period_end),
           cancel_at_period_end: false
         }}
      )

      assert {:ok, updated} = Billing.resync_from_stripe(user)
      assert updated.subscription_status == "active"
      assert updated.current_period_end == period_end
      assert updated.subscription_synced_at
    end

    test "a webhook event older than the resync is dropped as stale" do
      user =
        billing_state(insert_verified_user(),
          subscription_status: "past_due",
          stripe_customer_id: "cus_resync_stale",
          stripe_subscription_id: "sub_resync_stale"
        )

      stub_retrieve(
        "sub_resync_stale",
        {:ok, %Stripe.Subscription{id: "sub_resync_stale", status: "active", trial_end: nil}}
      )

      assert {:ok, _} = Billing.resync_from_stripe(user)

      # A delayed delivery from before the repair must not undo it.
      old_event = %Stripe.Event{
        type: "customer.subscription.updated",
        created: DateTime.to_unix(DateTime.utc_now()) - 3600,
        data: %{
          object: %{
            id: "sub_resync_stale",
            customer: "cus_resync_stale",
            status: "canceled",
            trial_end: nil
          }
        }
      }

      assert {:ok, :stale} = Billing.sync_subscription(old_event)
      assert Repo.reload!(user).subscription_status == "active"
    end

    test "comped accounts are refused without touching Stripe" do
      user = user_with_status("comped")
      assert {:error, :comped} = Billing.resync_from_stripe(user)
      assert Repo.reload!(user).subscription_status == "comped"
    end

    test "no subscription of record enqueues StripeCustomerSync instead" do
      user = insert_verified_user()

      assert {:ok, :sync_enqueued} = Billing.resync_from_stripe(user)
      assert_enqueued(worker: Fountain.Workers.StripeCustomerSync, args: %{user_id: user.id})
    end

    test "a Stripe error is returned and the account is untouched" do
      user =
        billing_state(insert_verified_user(),
          subscription_status: "past_due",
          stripe_subscription_id: "sub_resync_err"
        )

      stub_retrieve("sub_resync_err", {:error, %Stripe.ApiErrors{message: "nope"}})

      assert {:error, %Stripe.ApiErrors{}} = Billing.resync_from_stripe(user)
      assert Repo.reload!(user).subscription_status == "past_due"
    end
  end

  describe "sync_subscription/1 — coerce_status catch-all" do
    setup do
      user = insert_verified_user()
      user = Repo.update!(Ecto.Changeset.change(user, stripe_customer_id: "cus_coerce_catchall"))
      {:ok, user: user}
    end

    test "unknown stripe status is coerced to past_due", %{user: _user} do
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{
          object: %{customer: "cus_coerce_catchall", status: "some_future_status", trial_end: nil}
        }
      }

      assert {:ok, updated_user} = Billing.sync_subscription(event)
      assert updated_user.subscription_status == "past_due"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp user_with_status(status) do
    user = insert_verified_user()
    Ecto.Changeset.change(user, subscription_status: status) |> Repo.update!()
  end

  defp user_with_customer(customer_id) do
    user = insert_verified_user()
    Ecto.Changeset.change(user, stripe_customer_id: customer_id) |> Repo.update!()
  end

  defp insert_event(user, event_type, inserted_at, metadata \\ %{}, resource_id \\ nil) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      user_id: user.id,
      event_type: event_type,
      inserted_at: inserted_at,
      metadata: metadata,
      resource_id: resource_id
    })
    |> Repo.insert!()
  end

  describe "extend_trial/2" do
    defp billing_state(user, attrs) do
      Repo.update!(Ecto.Changeset.change(user, attrs))
    end

    test "no Stripe customer: sets trialing and an end ~days from now" do
      user =
        billing_state(insert_verified_user(), subscription_status: "canceled", trial_ends_at: nil)

      assert {:ok, updated} = Billing.extend_trial(user, 7)
      assert updated.subscription_status == "trialing"

      expected = DateTime.add(DateTime.utc_now(), 7 * 24 * 60 * 60, :second)
      assert abs(DateTime.diff(updated.trial_ends_at, expected, :second)) < 60
    end

    test "extends from the current end when it is in the future — never shortens" do
      future =
        DateTime.utc_now()
        |> DateTime.add(10 * 24 * 60 * 60, :second)
        |> DateTime.truncate(:second)

      user =
        billing_state(insert_verified_user(),
          subscription_status: "trialing",
          trial_ends_at: future
        )

      assert {:ok, updated} = Billing.extend_trial(user, 7)

      expected = DateTime.add(future, 7 * 24 * 60 * 60, :second)
      assert abs(DateTime.diff(updated.trial_ends_at, expected, :second)) < 60
    end

    test "with a trialing Stripe subscription: pushes the new end to Stripe first" do
      user =
        billing_state(insert_verified_user(),
          subscription_status: "trialing",
          stripe_customer_id: "cus_ext1",
          trial_ends_at: nil
        )

      stub(Stripe.Subscription, :list, fn %{customer: "cus_ext1", status: :trialing} ->
        {:ok, %{data: [%Stripe.Subscription{id: "sub_ext1", status: "trialing"}]}}
      end)

      test_pid = self()

      stub(Stripe.Subscription, :update, fn "sub_ext1", params ->
        send(test_pid, {:stripe_update, params})
        {:ok, %Stripe.Subscription{id: "sub_ext1", status: "trialing"}}
      end)

      assert {:ok, updated} = Billing.extend_trial(user, 14)
      assert_receive {:stripe_update, %{trial_end: unix, proration_behavior: :none}}
      assert unix == DateTime.to_unix(updated.trial_ends_at)
    end

    test "a Stripe refusal leaves the user unchanged" do
      user =
        billing_state(insert_verified_user(),
          subscription_status: "trialing",
          stripe_customer_id: "cus_ext2",
          trial_ends_at: nil
        )

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok, %{data: [%Stripe.Subscription{id: "sub_ext2", status: "trialing"}]}}
      end)

      stub(Stripe.Subscription, :update, fn _, _ -> {:error, :stripe_down} end)

      assert {:error, :stripe_down} = Billing.extend_trial(user, 14)
      assert Repo.reload!(user).trial_ends_at == nil
    end

    test "refused for active and comped accounts" do
      active = billing_state(insert_verified_user(), subscription_status: "active")
      comped = billing_state(insert_verified_user(), subscription_status: "comped")

      assert {:error, :active_subscription} = Billing.extend_trial(active, 7)
      assert {:error, :comped} = Billing.extend_trial(comped, 7)
    end

    test "a straggler webhook cannot revert the extension" do
      # The #334 shape: the operator re-opens a canceled account, then a
      # delayed event from the old subscription arrives. Its `created` predates
      # the extension, so the stamp the extension writes makes it stale.
      user =
        billing_state(insert_verified_user(),
          subscription_status: "canceled",
          stripe_customer_id: "cus_straggler",
          stripe_subscription_id: "sub_straggler",
          trial_ends_at: nil
        )

      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: []}} end)

      straggler_created = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.to_unix()

      assert {:ok, extended} = Billing.extend_trial(user, 7)
      assert extended.subscription_status == "trialing"

      assert {:ok, :stale} =
               Billing.sync_subscription(%Stripe.Event{
                 id: "evt_straggler",
                 type: "customer.subscription.deleted",
                 created: straggler_created,
                 data: %{
                   object: %{
                     id: "sub_straggler",
                     customer: "cus_straggler",
                     status: "canceled",
                     trial_end: nil
                   }
                 }
               })

      assert Repo.reload!(user).subscription_status == "trialing"
    end

    test "an event younger than the extension still applies" do
      # Stripe stays authoritative for what happens after the operator acted —
      # the stamp only outranks the past, not the future.
      user =
        billing_state(insert_verified_user(),
          subscription_status: "canceled",
          stripe_customer_id: "cus_after_ext",
          stripe_subscription_id: "sub_after_ext",
          trial_ends_at: nil
        )

      stub(Stripe.Subscription, :list, fn _ -> {:ok, %{data: []}} end)

      assert {:ok, _} = Billing.extend_trial(user, 7)

      later = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.to_unix()

      assert {:ok, updated} =
               Billing.sync_subscription(%Stripe.Event{
                 id: "evt_after_ext",
                 type: "customer.subscription.updated",
                 created: later,
                 data: %{
                   object: %{
                     id: "sub_after_ext",
                     customer: "cus_after_ext",
                     status: "active",
                     trial_end: nil
                   }
                 }
               })

      assert updated.subscription_status == "active"
    end
  end

  describe "comp_account/1 and revoke_comp/1" do
    test "comps an account with no Stripe customer" do
      user = insert_verified_user()

      assert {:ok, updated} = Billing.comp_account(user)
      assert updated.subscription_status == "comped"
      assert Billing.check_active(updated) == :ok
    end

    test "cancels live Stripe subscriptions before comping" do
      user =
        Repo.update!(
          Ecto.Changeset.change(insert_verified_user(), stripe_customer_id: "cus_comp1")
        )

      stub(Stripe.Subscription, :list, fn %{customer: "cus_comp1"} ->
        {:ok,
         %{data: [%Stripe.Subscription{id: "sub_comp1", status: "trialing"}], has_more: false}}
      end)

      test_pid = self()

      stub(Stripe.Subscription, :cancel, fn id ->
        send(test_pid, {:cancelled, id})
        {:ok, %Stripe.Subscription{id: id, status: "canceled"}}
      end)

      assert {:ok, updated} = Billing.comp_account(user)
      assert updated.subscription_status == "comped"
      assert_receive {:cancelled, "sub_comp1"}
    end

    test "a failed Stripe cancellation leaves the account un-comped" do
      user =
        Repo.update!(
          Ecto.Changeset.change(insert_verified_user(), stripe_customer_id: "cus_comp2")
        )

      stub(Stripe.Subscription, :list, fn _ -> {:error, :stripe_down} end)

      assert {:error, :stripe_down} = Billing.comp_account(user)
      refute Repo.reload!(user).subscription_status == "comped"
    end

    test "webhook sync does not override a comp" do
      user =
        Repo.update!(
          Ecto.Changeset.change(insert_verified_user(),
            stripe_customer_id: "cus_comp3",
            subscription_status: "comped"
          )
        )

      event = %Stripe.Event{
        type: "customer.subscription.deleted",
        data: %{object: %{customer: "cus_comp3", status: "canceled", trial_end: nil}}
      }

      assert {:ok, :comped_ignored} = Billing.sync_subscription(event)
      assert Repo.reload!(user).subscription_status == "comped"
    end

    test "revoke_comp moves a comped account to canceled, and refuses others" do
      user =
        Repo.update!(Ecto.Changeset.change(insert_verified_user(), subscription_status: "comped"))

      assert {:ok, updated} = Billing.revoke_comp(user)
      assert updated.subscription_status == "canceled"
      assert {:error, :not_comped} = Billing.revoke_comp(updated)
    end
  end

  describe "usage_summaries/2" do
    test "aggregates per user in the window, absent users omitted" do
      a = insert_verified_user()
      b = insert_verified_user()
      quiet = insert_verified_user()

      {:ok, _} = Billing.record_usage(a.id, "sandbox_provisioned", nil, nil)
      {:ok, _} = Billing.record_usage(a.id, "turn_started", nil, nil)
      {:ok, _} = Billing.record_usage(a.id, "turn_started", nil, nil)

      {:ok, _} =
        Billing.record_usage(a.id, "sandbox_terminated", nil, nil, %{"duration_ms" => 120_000})

      {:ok, _} = Billing.record_usage(b.id, "turn_started", nil, nil)

      now = DateTime.utc_now()
      summaries = Billing.usage_summaries(DateTime.add(now, -1, :day), DateTime.add(now, 1, :day))

      assert summaries[a.id] == %{conversations: 1, turns: 2, sandbox_minutes: 2.0}
      assert summaries[b.id] == %{conversations: 0, turns: 1, sandbox_minutes: 0.0}
      refute Map.has_key?(summaries, quiet.id)
    end

    test "failed provisioning attempts count as conversations" do
      a = insert_verified_user()

      {:ok, _} = Billing.record_usage(a.id, "sandbox_provisioned", nil, nil)
      {:ok, _} = Billing.record_usage(a.id, "sandbox_provision_failed", nil, nil)

      now = DateTime.utc_now()
      summaries = Billing.usage_summaries(DateTime.add(now, -1, :day), DateTime.add(now, 1, :day))

      assert summaries[a.id].conversations == 2
    end

    test "subtracts parked time per sandbox, per user (#665)" do
      a = insert_verified_user()
      b = insert_verified_user()
      sandbox_a = Ecto.UUID.generate()
      sandbox_b = Ecto.UUID.generate()

      # a: alive an hour, parked 30 of those minutes -> nets 30.
      insert_event(a, "sandbox_suspended", ~U[2026-05-10 12:20:00Z], %{}, sandbox_a)
      insert_event(a, "sandbox_resumed", ~U[2026-05-10 12:50:00Z], %{}, sandbox_a)

      insert_event(
        a,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 3_600_000},
        sandbox_a
      )

      # b: alive an hour, never suspended -> nets the full 60.
      insert_event(
        b,
        "sandbox_terminated",
        ~U[2026-05-10 13:00:00Z],
        %{"duration_ms" => 3_600_000},
        sandbox_b
      )

      summaries =
        Billing.usage_summaries(~U[2026-05-01 00:00:00Z], ~U[2026-06-01 00:00:00Z])

      assert summaries[a.id].sandbox_minutes == 30.0
      assert summaries[b.id].sandbox_minutes == 60.0
    end
  end

  describe "attach_stripe_customer/2" do
    test "a customer id cannot be attached to two users" do
      # Two users sharing a stripe_customer_id would make the webhook lookup
      # raise Ecto.MultipleResultsError, 500ing every delivery for that
      # customer through Stripe's whole retry window.
      u1 = insert_verified_user()
      u2 = insert_verified_user()

      assert {:ok, _} = Billing.attach_stripe_customer(u1, "cus_dup")
      assert {:error, changeset} = Billing.attach_stripe_customer(u2, "cus_dup")
      assert "has already been taken" in errors_on(changeset).stripe_customer_id
    end
  end

  # ── invoice.* events (#447) ────────────────────────────────────────────────

  defp invoice_user(status, opts \\ []) do
    user = insert_verified_user()

    Repo.update!(
      Ecto.Changeset.change(user,
        stripe_customer_id: "cus_inv#{System.unique_integer([:positive])}",
        stripe_subscription_id: Keyword.get(opts, :sub_id, "sub_of_record"),
        subscription_status: status,
        subscription_synced_at: Keyword.get(opts, :synced_at)
      )
    )
  end

  defp invoice_event(type, user, opts \\ []) do
    %Stripe.Event{
      type: type,
      created: Keyword.get(opts, :created),
      data: %{
        object: %{
          customer: user.stripe_customer_id,
          subscription: Keyword.get(opts, :subscription, user.stripe_subscription_id)
        }
      }
    }
  end

  describe "invoice.* events (#447)" do
    alias Fountain.Workers.LifecycleEmail

    test "invoice.payment_failed enqueues the dunning email without touching status" do
      user = invoice_user("active")

      assert {:ok, %Fountain.Accounts.User{}} =
               Billing.sync_subscription(invoice_event("invoice.payment_failed", user))

      # status stays with the subscription events
      assert Repo.reload(user).subscription_status == "active"

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "payment_failed"}
      )
    end

    test "invoice.payment_action_required enqueues the SCA email" do
      user = invoice_user("active")

      assert {:ok, %Fountain.Accounts.User{}} =
               Billing.sync_subscription(invoice_event("invoice.payment_action_required", user))

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "payment_action_required"}
      )
    end

    test "an invoice for another subscription never reaches the account" do
      user = invoice_user("past_due")

      assert {:ok, :other_subscription} =
               Billing.sync_subscription(
                 invoice_event("invoice.payment_failed", user, subscription: "sub_other")
               )

      refute_enqueued(worker: LifecycleEmail)
    end

    test "an unknown customer is ignored, not an error — deleted accounts trail invoices" do
      event = %Stripe.Event{
        type: "invoice.payment_failed",
        data: %{object: %{customer: "cus_gone_forever", subscription: "sub_x"}}
      }

      assert {:ok, :ignored} = Billing.sync_subscription(event)
    end

    test "a comped account is never touched by invoice events" do
      user = invoice_user("comped")

      assert {:ok, :comped_ignored} =
               Billing.sync_subscription(invoice_event("invoice.payment_failed", user))

      assert {:ok, :comped_ignored} =
               Billing.sync_subscription(invoice_event("invoice.paid", user))

      refute_enqueued(worker: LifecycleEmail)
    end

    test "invoice.paid recovers past_due → active and advances the watermark" do
      ts = 1_800_000_000
      user = invoice_user("past_due")

      assert {:ok, updated} =
               Billing.sync_subscription(invoice_event("invoice.paid", user, created: ts))

      assert updated.subscription_status == "active"
      assert updated.subscription_synced_at == DateTime.from_unix!(ts)

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "payment_recovered"}
      )
    end

    test "invoice.paid off any state but past_due is a no-op — the $0 trial invoice" do
      # Stripe pays a $0 invoice the moment a trial subscription is created;
      # applying it would flip a fresh trialing account straight to active.
      user = invoice_user("trialing")

      assert {:ok, :ignored} = Billing.sync_subscription(invoice_event("invoice.paid", user))
      assert Repo.reload(user).subscription_status == "trialing"
      refute_enqueued(worker: LifecycleEmail)
    end

    test "a stale invoice.paid cannot move the account" do
      synced = ~U[2026-08-01 00:00:00Z]
      user = invoice_user("past_due", synced_at: synced)
      old_ts = DateTime.to_unix(synced) - 3600

      assert {:ok, :stale} =
               Billing.sync_subscription(invoice_event("invoice.paid", user, created: old_ts))

      assert Repo.reload(user).subscription_status == "past_due"
    end

    test "invoice.paid for another subscription is ignored even off past_due" do
      user = invoice_user("past_due")

      assert {:ok, :other_subscription} =
               Billing.sync_subscription(
                 invoice_event("invoice.paid", user, subscription: "sub_other")
               )

      assert Repo.reload(user).subscription_status == "past_due"
    end
  end
end
