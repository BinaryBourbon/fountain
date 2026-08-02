defmodule Fountain.TrialEndingEmailTest do
  @moduledoc """
  The three-day warning before a trial ends.

  Stripe fires `customer.subscription.trial_will_end` three days out, and the
  webhook handler received it, parsed it and dropped it on the catch-all. That
  was survivable while trials never ended. Since #153 they do, so the failure
  mode changed from "free forever" to "cut off with no warning" — someone using
  Fountain daily hits a 402 and the first they hear of it is a broken workflow.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.{Billing, Emails.UserEmails}
  alias Fountain.Workers.TrialEndingEmail

  setup :set_mimic_global

  defp trialing_user(attrs \\ %{}) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> User.billing_changeset(
        Map.merge(
          %{
            stripe_customer_id: "cus_#{System.unique_integer([:positive])}",
            subscription_status: "trialing"
          },
          attrs
        )
      )
      |> Repo.update()

    user
  end

  defp trial_will_end_event(customer_id, trial_end) do
    %Stripe.Event{
      id: "evt_#{System.unique_integer([:positive])}",
      type: "customer.subscription.trial_will_end",
      created: System.system_time(:second),
      data: %{object: %{id: "sub_x", customer: customer_id, trial_end: trial_end}}
    }
  end

  describe "the webhook" do
    test "enqueues the warning instead of dropping the event" do
      user = trialing_user()
      ends = DateTime.utc_now() |> DateTime.add(3 * 86_400, :second) |> DateTime.truncate(:second)

      assert {:ok, %User{}} =
               Billing.sync_subscription(
                 trial_will_end_event(user.stripe_customer_id, DateTime.to_unix(ends))
               )

      assert_enqueued(worker: TrialEndingEmail, args: %{"user_id" => user.id})
    end

    test "an unknown customer is ignored rather than erroring" do
      # Stripe sends events for objects we may not know about. Returning an
      # error would make it retry the webhook forever.
      assert {:ok, :ignored} =
               Billing.sync_subscription(trial_will_end_event("cus_stranger", nil))

      refute_enqueued(worker: TrialEndingEmail)
    end

    test "a redelivered event does not send twice" do
      # handle_event/1 claims each Stripe event id exactly once, so the second
      # delivery never reaches sync_subscription at all.
      user = trialing_user()
      event = trial_will_end_event(user.stripe_customer_id, nil)

      assert {:ok, %User{}} = Billing.handle_event(event)
      assert {:ok, :duplicate} = Billing.handle_event(event)

      assert length(all_enqueued(worker: TrialEndingEmail)) == 1
    end
  end

  describe "the job" do
    test "sends to a user still on trial" do
      user = trialing_user()
      test = self()

      stub(Fountain.Mailer, :deliver, fn email ->
        send(test, {:email, email})
        {:ok, %{}}
      end)

      assert :ok = perform_job(TrialEndingEmail, %{"user_id" => user.id, "trial_ends_at" => nil})

      assert_received {:email, email}
      assert email.to == [{user.email, user.email}]
      assert email.subject =~ "trial ends"
    end

    test "does not send to someone who already subscribed" do
      # The event fires three days out. Telling a paying customer their trial is
      # ending is both wrong and alarming.
      user = trialing_user(%{subscription_status: "active"})
      reject(&Fountain.Mailer.deliver/1)

      assert :ok = perform_job(TrialEndingEmail, %{"user_id" => user.id, "trial_ends_at" => nil})
    end

    test "a deleted account is not an error" do
      # Deleted between the webhook and the send. Retrying will not bring them
      # back, so the job must not fail forever.
      reject(&Fountain.Mailer.deliver/1)

      assert :ok =
               perform_job(TrialEndingEmail, %{
                 "user_id" => Ecto.UUID.generate(),
                 "trial_ends_at" => nil
               })
    end

    test "a delivery failure returns an error so Oban retries" do
      user = trialing_user()
      stub(Fountain.Mailer, :deliver, fn _ -> {:error, :smtp_down} end)

      assert {:error, :smtp_down} =
               perform_job(TrialEndingEmail, %{"user_id" => user.id, "trial_ends_at" => nil})
    end
  end

  describe "what the email says" do
    setup do
      test = self()
      stub(Fountain.Mailer, :deliver, fn email -> send(test, {:email, email}) && {:ok, %{}} end)
      :ok
    end

    defp sent_email(user, ends_at) do
      UserEmails.deliver_trial_ending_email(user, ends_at)
      assert_received {:email, email}
      email
    end

    test "says when, in days and as a date" do
      user = trialing_user()
      ends = DateTime.utc_now() |> DateTime.add(3 * 86_400 + 3600, :second)

      email = sent_email(user, ends)

      assert email.subject =~ "in 3 days"
      assert email.html_body =~ Calendar.strftime(ends, "%-d %B")
    end

    test "handles today and tomorrow without saying 'in 0 days'" do
      user = trialing_user()

      assert sent_email(user, DateTime.add(DateTime.utc_now(), 3600, :second)).subject =~ "today"

      assert sent_email(user, DateTime.add(DateTime.utc_now(), 86_400 + 3600, :second)).subject =~
               "tomorrow"
    end

    test "is explicit that nothing is deleted" do
      # #170 made account deletion real. Someone skim-reading "your trial is
      # ending" must not conclude their agents and history are about to go.
      email = sent_email(trialing_user(), nil)

      assert email.html_body =~ "Nothing is deleted"
      assert email.text_body =~ "Nothing is deleted"
      assert email.html_body =~ "conversation history"
    end

    test "links to billing, in both parts" do
      email = sent_email(trialing_user(), nil)

      assert email.html_body =~ "/account/billing"
      assert email.text_body =~ "/account/billing"
    end

    test "says what actually stops" do
      # Whitespace-normalised: the text part is hard-wrapped, so a phrase that
      # straddles a line break would fail on formatting rather than content.
      email = sent_email(trialing_user(), nil)
      flat = email.text_body |> String.replace(~r/\s+/, " ")

      assert flat =~ "subscription will be cancelled and running sandboxes will stop"
    end
  end
end
