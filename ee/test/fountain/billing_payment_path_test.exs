defmodule Fountain.BillingPaymentPathTest do
  @moduledoc """
  The path from "user clicks Upgrade" to "account is active".

  It had a hole big enough to take money through. When a user had no
  `stripe_customer_id`, Checkout was opened with `customer_email`, so Stripe
  minted its own Customer whose id we never learned. The resulting
  `customer.subscription.created` webhook then matched no user, the controller
  logged it and answered 200, and the card was charged against an account that
  stayed unactivated. Roughly 80% of accounts had no customer id, so this was
  the common case rather than an edge.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Accounts, Billing, Repo}
  alias Fountain.Accounts.User

  describe "ensure_stripe_customer/1" do
    test "creates a customer when the user has none" do
      user = insert_verified_user()
      refute user.stripe_customer_id

      expect(Stripe.Customer, :create, fn %{email: email} ->
        assert email == user.email
        {:ok, %Stripe.Customer{id: "cus_new123"}}
      end)

      assert {:ok, updated} = Billing.ensure_stripe_customer(user)
      assert updated.stripe_customer_id == "cus_new123"
      assert Repo.get(User, user.id).stripe_customer_id == "cus_new123"
    end

    test "reuses an existing customer without calling Stripe" do
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_existing")

      # No expect/3 on Stripe.Customer — a call would fail the test.
      assert {:ok, same} = Billing.ensure_stripe_customer(user)
      assert same.stripe_customer_id == "cus_existing"
    end

    test "sets a trial end date alongside the customer" do
      user = insert_verified_user()
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_t"}} end)

      assert {:ok, updated} = Billing.ensure_stripe_customer(user)
      assert updated.trial_ends_at
      assert DateTime.compare(updated.trial_ends_at, DateTime.utc_now()) == :gt
    end

    test "propagates a Stripe failure rather than returning a customerless user" do
      user = insert_verified_user()

      stub(Stripe.Customer, :create, fn _ ->
        {:error, %Stripe.Error{source: :stripe, code: :api_error, message: "nope"}}
      end)

      assert {:error, _} = Billing.ensure_stripe_customer(user)
      refute Repo.get(User, user.id).stripe_customer_id
    end
  end

  describe "checkout.session.completed" do
    defp checkout_event(customer, client_reference_id) do
      %Stripe.Event{
        type: "checkout.session.completed",
        data: %{object: %{customer: customer, client_reference_id: client_reference_id}}
      }
    end

    test "backfills the customer id via client_reference_id" do
      user = insert_verified_user()
      refute user.stripe_customer_id

      assert {:ok, updated} = Billing.sync_subscription(checkout_event("cus_orphan", user.id))
      assert updated.stripe_customer_id == "cus_orphan"
    end

    test "is a no-op when the customer is already linked" do
      user = insert_verified_user()
      {:ok, _} = Billing.attach_stripe_customer(user, "cus_known")

      assert {:ok, :ignored} = Billing.sync_subscription(checkout_event("cus_known", user.id))
    end

    test "reports an unknown client_reference_id rather than silently passing" do
      assert {:error, :user_not_found} =
               Billing.sync_subscription(checkout_event("cus_x", Ecto.UUID.generate()))
    end

    test "ignores a session with no customer" do
      assert {:ok, :ignored} = Billing.sync_subscription(checkout_event(nil, nil))
    end

    test "after backfill, the subscription webhook can find the user" do
      # The end-to-end point: this is what turns a charged-but-inactive account
      # into an active one.
      user = insert_verified_user()
      {:ok, _} = Billing.sync_subscription(checkout_event("cus_flow", user.id))

      event = %Stripe.Event{
        type: "customer.subscription.created",
        data: %{object: %{customer: "cus_flow", status: "active", trial_end: nil}}
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      assert updated.id == user.id
      assert updated.subscription_status == "active"
    end
  end

  describe "mid-trial upgrade" do
    # The #309 chain: Checkout in subscription mode always creates a *new*
    # subscription, so an upgrade during the trial leaves two alive. Stripe
    # then cancels the trial one (created with missing_payment_method: :cancel)
    # at trial end, and customer-keyed sync applied that cancellation to the
    # account of a customer who is paying on the other subscription.

    defp trialing_user_on(customer_id, sub_id) do
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, customer_id)

      {:ok, user} =
        user
        |> User.billing_changeset(%{stripe_subscription_id: sub_id})
        |> Repo.update()

      user
    end

    defp sub_event(id, type, customer, sub_id, status, created) do
      %Stripe.Event{
        id: id,
        type: type,
        created: created,
        data: %{object: %{id: sub_id, customer: customer, status: status, trial_end: nil}}
      }
    end

    defp now_unix, do: DateTime.utc_now() |> DateTime.to_unix()

    test "checkout completion adopts the new subscription and cancels the trial one" do
      user = trialing_user_on("cus_upgrade", "sub_trial")
      test = self()

      expect(Stripe.Subscription, :list, fn %{customer: "cus_upgrade", status: :all} ->
        {:ok,
         %{
           data: [
             %Stripe.Subscription{id: "sub_trial", status: "trialing"},
             %Stripe.Subscription{id: "sub_paid", status: "active"}
           ],
           has_more: false
         }}
      end)

      expect(Stripe.Subscription, :cancel, fn id ->
        send(test, {:cancelled, id})
        {:ok, %Stripe.Subscription{id: id, status: "canceled"}}
      end)

      event = %Stripe.Event{
        id: "evt_checkout_up",
        type: "checkout.session.completed",
        created: now_unix(),
        data: %{
          object: %{
            customer: "cus_upgrade",
            subscription: "sub_paid",
            client_reference_id: user.id
          }
        }
      }

      assert {:ok, updated} = Billing.handle_event(event)
      assert updated.stripe_subscription_id == "sub_paid"
      assert updated.subscription_status == "active"

      # Only the trial subscription is cancelled — never the one just paid for.
      assert_received {:cancelled, "sub_trial"}
      refute_received {:cancelled, "sub_paid"}
    end

    test "the dead trial subscription's deletion cannot lock out the paying account" do
      # Both halves on one path: the upgrade above, then the straggler event
      # Stripe sends when the abandoned trial subscription dies.
      user = trialing_user_on("cus_locked", "sub_trial2")

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok, %{data: [%Stripe.Subscription{id: "sub_trial2", status: "trialing"}], has_more: false}}
      end)

      stub(Stripe.Subscription, :cancel, fn id ->
        {:ok, %Stripe.Subscription{id: id, status: "canceled"}}
      end)

      t0 = now_unix()

      {:ok, _} =
        Billing.handle_event(%Stripe.Event{
          id: "evt_up2",
          type: "checkout.session.completed",
          created: t0,
          data: %{
            object: %{
              customer: "cus_locked",
              subscription: "sub_paid2",
              client_reference_id: user.id
            }
          }
        })

      # The deletion for the old subscription arrives later, so the staleness
      # guard alone would have let it through.
      assert {:ok, :other_subscription} =
               Billing.handle_event(
                 sub_event(
                   "evt_trial_dies",
                   "customer.subscription.deleted",
                   "cus_locked",
                   "sub_trial2",
                   "canceled",
                   t0 + 60
                 )
               )

      reloaded = Repo.reload(user)
      assert reloaded.subscription_status == "active"
      assert reloaded.stripe_subscription_id == "sub_paid2"

      # The subscription of record still syncs normally.
      assert {:ok, updated} =
               Billing.handle_event(
                 sub_event(
                   "evt_paid_pd",
                   "customer.subscription.updated",
                   "cus_locked",
                   "sub_paid2",
                   "past_due",
                   t0 + 120
                 )
               )

      assert updated.subscription_status == "past_due"
    end

    test "a legacy account with no recorded subscription adopts from the first live event" do
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_legacy")

      assert {:ok, updated} =
               Billing.sync_subscription(
                 sub_event(
                   "evt_legacy",
                   "customer.subscription.updated",
                   "cus_legacy",
                   "sub_adopted",
                   "active",
                   now_unix()
                 )
               )

      assert updated.stripe_subscription_id == "sub_adopted"
      assert updated.subscription_status == "active"
      assert Repo.reload(user).stripe_subscription_id == "sub_adopted"
    end

    test "a legacy account applies but does not adopt from a deletion" do
      # During a pre-fix double-subscription window the dying trial must not
      # become the subscription of record; the paying subscription's next
      # event adopts and corrects instead.
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_legacy_del")
      t0 = now_unix()

      assert {:ok, updated} =
               Billing.sync_subscription(
                 sub_event(
                   "evt_legacy_del",
                   "customer.subscription.deleted",
                   "cus_legacy_del",
                   "sub_doomed",
                   "canceled",
                   t0
                 )
               )

      assert updated.subscription_status == "canceled"
      assert updated.stripe_subscription_id == nil

      # The paying subscription's monthly event recovers the account.
      assert {:ok, recovered} =
               Billing.sync_subscription(
                 sub_event(
                   "evt_legacy_rec",
                   "customer.subscription.updated",
                   "cus_legacy_del",
                   "sub_alive",
                   "active",
                   t0 + 60
                 )
               )

      assert recovered.subscription_status == "active"
      assert recovered.stripe_subscription_id == "sub_alive"
      assert Repo.reload(user).subscription_status == "active"
    end

    test "a failed Stripe cancel rolls the whole checkout apply back for redelivery" do
      user = trialing_user_on("cus_rollback", "sub_trial3")

      stub(Stripe.Subscription, :list, fn _ -> {:error, :stripe_down} end)

      event = %Stripe.Event{
        id: "evt_up_fail",
        type: "checkout.session.completed",
        created: now_unix(),
        data: %{
          object: %{
            customer: "cus_rollback",
            subscription: "sub_paid3",
            client_reference_id: user.id
          }
        }
      }

      assert {:error, :stripe_down} = Billing.handle_event(event)

      # Nothing half-applied, and the event id is unclaimed for the retry.
      reloaded = Repo.reload(user)
      assert reloaded.stripe_subscription_id == "sub_trial3"

      stub(Stripe.Subscription, :list, fn _ ->
        {:ok, %{data: [%Stripe.Subscription{id: "sub_trial3", status: "trialing"}], has_more: false}}
      end)

      stub(Stripe.Subscription, :cancel, fn id ->
        {:ok, %Stripe.Subscription{id: id, status: "canceled"}}
      end)

      assert {:ok, updated} = Billing.handle_event(event)
      assert updated.stripe_subscription_id == "sub_paid3"
      assert updated.subscription_status == "active"
    end
  end

  describe "comped checkout backstop (#399)" do
    test "a completed checkout records the subscription id without un-comping" do
      # The page-level fix stops Checkout being offered; this is the backstop
      # for a session opened before the comp (or a stale tab): the customer
      # IS being charged, so the app must at least hold the reference —
      # pre-#399 the adoption dropped it, making the subscription invisible
      # to the MRR tile and to revoke_comp.
      user = insert_verified_user()
      {:ok, user} = Billing.attach_stripe_customer(user, "cus_comped_bs")

      {:ok, user} =
        user
        |> User.billing_changeset(%{subscription_status: "comped"})
        |> Repo.update()

      test_pid = self()

      stub(Stripe.Subscription, :list, fn _ ->
        send(test_pid, :list_called)
        {:ok, %{data: [], has_more: false}}
      end)

      event = %Stripe.Event{
        id: "evt_comped_bs",
        type: "checkout.session.completed",
        created: DateTime.utc_now() |> DateTime.to_unix(),
        data: %{
          object: %{
            customer: "cus_comped_bs",
            subscription: "sub_comped_paid",
            client_reference_id: user.id
          }
        }
      }

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, %User{}} = Billing.handle_event(event)
        end)

      reloaded = Repo.reload(user)
      assert reloaded.subscription_status == "comped"
      assert reloaded.stripe_subscription_id == "sub_comped_paid"
      assert log =~ "comped user #{user.id} completed checkout"

      # Comped accounts skip the cancellation sweep — comp_account already
      # cancelled everything, and a webhook must not touch the rest.
      refute_received :list_called
    end
  end

  describe "OAuth signups" do
    test "get a Stripe customer and a trial end date" do
      # The email+password path creates the customer after verification. OAuth
      # skips verification, so it used to create neither — every GitHub user
      # then walked into the orphaned-checkout bug above.
      stub(Stripe.Customer, :create, fn _ -> {:ok, %Stripe.Customer{id: "cus_oauth"}} end)

      {:ok, user, :new} =
        Accounts.upsert_oauth_user("github", "gh-#{System.unique_integer([:positive])}", %{
          "email" => "oauth-#{System.unique_integer([:positive])}@example.com"
        })

      {:ok, updated} = Billing.create_stripe_customer(user)

      assert updated.stripe_customer_id == "cus_oauth"
      assert updated.trial_ends_at
    end
  end
end
