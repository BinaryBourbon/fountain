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

  defp insert_event(user, event_type, inserted_at, metadata \\ %{}) do
    %UsageEvent{}
    |> UsageEvent.changeset(%{
      user_id: user.id,
      event_type: event_type,
      inserted_at: inserted_at,
      metadata: metadata
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
  end
end
