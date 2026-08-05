defmodule Fountain.LifecycleEmailTest do
  @moduledoc """
  The three lifecycle emails after the trial-ending warning (#283): trial
  expired, payment failed, subscription cancelled.

  The email lifecycle used to stop at the three-day warning. After that the
  user heard nothing: the trial expired and the first sign was a 402, a card
  bounced and the only notice was a banner on a page they had no reason to
  visit, a cancellation happened silently. These tests pin the webhook
  transition → email mapping, the idempotency layers, and what the emails say.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.{Billing, Emails.BillingEmails}
  alias Fountain.Workers.LifecycleEmail

  setup :set_mimic_global

  defp user_with_status(status, attrs \\ %{}) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> User.billing_changeset(
        Map.merge(
          %{
            stripe_customer_id: "cus_#{System.unique_integer([:positive])}",
            subscription_status: status
          },
          attrs
        )
      )
      |> Repo.update()

    user
  end

  defp subscription_event(type, customer_id, stripe_status) do
    %Stripe.Event{
      id: "evt_#{System.unique_integer([:positive])}",
      type: type,
      created: System.system_time(:second),
      data: %{
        object: %{id: "sub_x", customer: customer_id, status: stripe_status, trial_end: nil}
      }
    }
  end

  describe "webhook transitions that send" do
    test "a trial that runs out enqueues the trial-expired email" do
      # missing_payment_method: :cancel deletes the subscription at trial end,
      # so trialing → canceled via .deleted is the trial-expiry signal.
      user = user_with_status("trialing")

      assert {:ok, %User{subscription_status: "canceled"}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.deleted",
                   user.stripe_customer_id,
                   "canceled"
                 )
               )

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "trial_expired"}
      )
    end

    test "a payment failure enqueues the dunning email" do
      user = user_with_status("active")

      assert {:ok, %User{subscription_status: "past_due"}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.updated",
                   user.stripe_customer_id,
                   "past_due"
                 )
               )

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "payment_failed"}
      )
    end

    test "a paying account's cancellation enqueues the confirmation" do
      user = user_with_status("active")

      assert {:ok, %User{subscription_status: "canceled"}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.deleted",
                   user.stripe_customer_id,
                   "canceled"
                 )
               )

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "subscription_canceled"}
      )
    end

    test "dunning exhaustion is a cancellation, not a trial expiry" do
      # past_due → canceled: they were paying, Stripe gave up. The trial-expiry
      # email ("subscribe to start") would be the wrong story.
      user = user_with_status("past_due")

      assert {:ok, %User{}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.deleted",
                   user.stripe_customer_id,
                   "canceled"
                 )
               )

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "subscription_canceled"}
      )

      refute_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "trial_expired"}
      )
    end
  end

  describe "webhook transitions that send (#447 additions)" do
    test "dunning recovery via the subscription event enqueues payment_recovered" do
      user = user_with_status("past_due")

      assert {:ok, %User{subscription_status: "active"}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.updated",
                   user.stripe_customer_id,
                   "active"
                 )
               )

      assert_enqueued(
        worker: LifecycleEmail,
        args: %{"user_id" => user.id, "email" => "payment_recovered"}
      )
    end
  end

  describe "webhook transitions that stay silent" do
    test "a second past_due event in the same dunning cycle does not re-send" do
      # Stripe fires several subscription.updated events per dunning cycle, all
      # carrying past_due. Only the transition into past_due is news.
      user = user_with_status("past_due")

      assert {:ok, %User{}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.updated",
                   user.stripe_customer_id,
                   "past_due"
                 )
               )

      refute_enqueued(worker: LifecycleEmail)
    end

    test "non-triggering transitions enqueue nothing" do
      # past_due → active moved out of this list in #447: dunning recovery
      # now sends payment_recovered (asserted in the sends describe above).
      for {old, stripe_status} <- [
            # trialing → active: they subscribed.
            {"trialing", "active"},
            # active → active: routine sync.
            {"active", "active"},
            # canceled → canceled: a distinct-but-equivalent event replay.
            {"canceled", "canceled"}
          ] do
        user = user_with_status(old)

        assert {:ok, %User{}} =
                 Billing.sync_subscription(
                   subscription_event(
                     "customer.subscription.updated",
                     user.stripe_customer_id,
                     stripe_status
                   )
                 )

        refute_enqueued(worker: LifecycleEmail, args: %{"user_id" => user.id})
      end
    end

    test "a comped account gets no lifecycle email" do
      # comp_account/1 cancels the Stripe subscription; the cancellation
      # webhook that follows must not email the person we just comped.
      user = user_with_status("comped")

      assert {:ok, :comped_ignored} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.deleted",
                   user.stripe_customer_id,
                   "canceled"
                 )
               )

      refute_enqueued(worker: LifecycleEmail)
    end

    test "a stale out-of-order event enqueues nothing" do
      synced = DateTime.utc_now() |> DateTime.truncate(:second)
      user = user_with_status("active", %{subscription_synced_at: synced})

      old_event = %Stripe.Event{
        id: "evt_#{System.unique_integer([:positive])}",
        type: "customer.subscription.deleted",
        created: DateTime.to_unix(synced) - 3600,
        data: %{
          object: %{
            id: "sub_x",
            customer: user.stripe_customer_id,
            status: "canceled",
            trial_end: nil
          }
        }
      }

      assert {:ok, :stale} = Billing.sync_subscription(old_event)
      refute_enqueued(worker: LifecycleEmail)
    end
  end

  describe "idempotency" do
    test "a redelivered event id does not enqueue twice" do
      # Layer 1: handle_event/1 claims each Stripe event id exactly once, so
      # the second delivery never reaches sync_subscription at all.
      user = user_with_status("active")

      event =
        subscription_event("customer.subscription.deleted", user.stripe_customer_id, "canceled")

      assert {:ok, %User{}} = Billing.handle_event(event)
      assert {:ok, :duplicate} = Billing.handle_event(event)

      assert length(all_enqueued(worker: LifecycleEmail)) == 1
    end

    test "Oban unique collapses duplicate enqueues within the window" do
      # Layer 3, the belt to the braces above: even if two distinct paths asked
      # for the same email on the same day, only one job exists.
      user = user_with_status("past_due")

      assert {:ok, _} = LifecycleEmail.enqueue(user.id, "payment_failed")
      assert {:ok, _} = LifecycleEmail.enqueue(user.id, "payment_failed")

      assert length(all_enqueued(worker: LifecycleEmail)) == 1
    end

    test "different emails for the same user are not collapsed" do
      user = user_with_status("past_due")

      assert {:ok, _} = LifecycleEmail.enqueue(user.id, "payment_failed")
      assert {:ok, _} = LifecycleEmail.enqueue(user.id, "subscription_canceled")

      assert length(all_enqueued(worker: LifecycleEmail)) == 2
    end
  end

  describe "the webhook never fails on mail plumbing" do
    test "an enqueue failure is logged, not returned" do
      # The whole point of the job indirection: Stripe must get its 200 and the
      # status sync must stand even if Oban refuses the insert.
      user = user_with_status("active")
      stub(LifecycleEmail, :enqueue, fn _user_id, _email -> {:error, :oban_down} end)

      assert {:ok, %User{subscription_status: "canceled"}} =
               Billing.sync_subscription(
                 subscription_event(
                   "customer.subscription.deleted",
                   user.stripe_customer_id,
                   "canceled"
                 )
               )
    end
  end

  describe "the job" do
    setup do
      test = self()

      stub(Fountain.Mailer, :deliver, fn email ->
        send(test, {:email, email})
        {:ok, %{}}
      end)

      :ok
    end

    test "sends trial-expired to a user still canceled" do
      user = user_with_status("canceled")

      assert :ok =
               perform_job(LifecycleEmail, %{"user_id" => user.id, "email" => "trial_expired"})

      assert_received {:email, email}
      assert email.to == [{user.email, user.email}]
      assert email.subject =~ "trial has ended"
    end

    test "sends payment-failed to a user still past_due" do
      user = user_with_status("past_due")

      assert :ok =
               perform_job(LifecycleEmail, %{"user_id" => user.id, "email" => "payment_failed"})

      assert_received {:email, email}
      assert email.to == [{user.email, user.email}]
      assert email.subject =~ "Payment failed"
    end

    test "sends the cancellation confirmation to a user still canceled" do
      user = user_with_status("canceled")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => user.id,
                 "email" => "subscription_canceled"
               })

      assert_received {:email, email}
      assert email.subject =~ "cancelled"
    end

    test "sends action-required to any live account, skips a canceled one (#447)" do
      for status <- ["trialing", "active", "past_due"] do
        user = user_with_status(status)

        assert :ok =
                 perform_job(LifecycleEmail, %{
                   "user_id" => user.id,
                   "email" => "payment_action_required"
                 })

        assert_received {:email, email}
        assert email.subject =~ "confirm your Fountain payment"
      end

      canceled = user_with_status("canceled")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => canceled.id,
                 "email" => "payment_action_required"
               })

      refute_received {:email, _}
    end

    test "sends payment-recovered only once the account is actually active (#447)" do
      active = user_with_status("active")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => active.id,
                 "email" => "payment_recovered"
               })

      assert_received {:email, email}
      assert email.subject =~ "Payment received"

      # Still past_due at send time: the recovery hasn't synced, and "you're
      # all set" while the gate is closed would be a lie.
      stuck = user_with_status("past_due")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => stuck.id,
                 "email" => "payment_recovered"
               })

      refute_received {:email, _}
    end

    test "does not send to someone whose state moved on" do
      # The queue can lag the account. Someone who subscribed after their trial
      # expired, or fixed their card an hour after it bounced, must not then be
      # told the opposite.
      reject(&Fountain.Mailer.deliver/1)

      subscribed = user_with_status("active")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => subscribed.id,
                 "email" => "trial_expired"
               })

      recovered = user_with_status("active")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => recovered.id,
                 "email" => "payment_failed"
               })

      resubscribed = user_with_status("active")

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => resubscribed.id,
                 "email" => "subscription_canceled"
               })
    end

    test "a deleted account is not an error" do
      reject(&Fountain.Mailer.deliver/1)

      assert :ok =
               perform_job(LifecycleEmail, %{
                 "user_id" => Ecto.UUID.generate(),
                 "email" => "trial_expired"
               })
    end

    test "a delivery failure returns an error so Oban retries" do
      user = user_with_status("past_due")
      stub(Fountain.Mailer, :deliver, fn _ -> {:error, :smtp_down} end)

      assert {:error, :smtp_down} =
               perform_job(LifecycleEmail, %{"user_id" => user.id, "email" => "payment_failed"})
    end
  end

  describe "what the emails say" do
    setup do
      test = self()
      stub(Fountain.Mailer, :deliver, fn email -> send(test, {:email, email}) && {:ok, %{}} end)
      :ok
    end

    defp sent(deliver_fun, user) do
      deliver_fun.(user)
      assert_received {:email, email}
      email
    end

    test "trial expired: checkout link and the retention story, in both parts" do
      email = sent(&BillingEmails.deliver_trial_expired_email/1, user_with_status("canceled"))

      assert email.html_body =~ "/account/billing"
      assert email.text_body =~ "/account/billing"
      assert email.html_body =~ "Nothing is deleted"
      assert email.text_body =~ "Nothing is deleted"
      assert email.html_body =~ "conversation history"
    end

    test "payment failed: says we retry, and where to fix the card" do
      email = sent(&BillingEmails.deliver_payment_failed_email/1, user_with_status("past_due"))
      flat = email.text_body |> String.replace(~r/\s+/, " ")

      assert email.subject =~ "Payment failed"
      assert flat =~ "retry the charge automatically"
      assert flat =~ "update your payment method"
      assert email.html_body =~ "/account/billing"
      assert email.text_body =~ "/account/billing"
    end

    test "payment failed: warns what happens if the retries keep failing" do
      email = sent(&BillingEmails.deliver_payment_failed_email/1, user_with_status("past_due"))
      flat = email.text_body |> String.replace(~r/\s+/, " ")

      assert flat =~ "your subscription will be cancelled"
    end

    test "action required: leads with the fix and says what happens otherwise (#447)" do
      email =
        sent(&BillingEmails.deliver_payment_action_required_email/1, user_with_status("active"))

      flat = email.text_body |> String.replace(~r/\s+/, " ")

      assert email.subject =~ "Action needed"
      assert flat =~ "bank is asking for an extra confirmation"
      assert flat =~ "treated as failed"
      assert email.html_body =~ "/account/billing"
      assert email.text_body =~ "/account/billing"
    end

    test "payment recovered: access is back and nothing was deleted (#447)" do
      email = sent(&BillingEmails.deliver_payment_recovered_email/1, user_with_status("active"))
      flat = email.text_body |> String.replace(~r/\s+/, " ")

      assert email.subject =~ "Payment received"
      assert flat =~ "active again"
      assert flat =~ "nothing was deleted"
      assert email.html_body =~ "/account/billing"
    end

    test "cancellation: no more charges, nothing deleted, and the way back" do
      email =
        sent(&BillingEmails.deliver_subscription_canceled_email/1, user_with_status("canceled"))

      flat = email.text_body |> String.replace(~r/\s+/, " ")

      assert flat =~ "will not be charged again"
      assert email.html_body =~ "Nothing is deleted"
      assert email.text_body =~ "Nothing is deleted"
      assert flat =~ "resubscribing"
      assert email.html_body =~ "/account/billing"
      assert email.text_body =~ "/account/billing"
    end
  end
end
