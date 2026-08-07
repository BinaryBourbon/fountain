defmodule Fountain.BillingAuditTest do
  @moduledoc """
  Subscription state changes leave a trail (#550).

  `Fountain.Billing` had zero `Audit.record` calls, so an account could move
  from `active` to `canceled` — or from `trialing` to gated — and the person it
  happened to saw only the result. Admin-initiated billing changes did land in
  `admin_audit_events`, but the tenant-facing `/audit` never reads that table,
  so from the user's own trail their subscription changed state for no stated
  reason.

  The `source` in each event is the point: "your subscription was cancelled"
  means something different depending on whether Stripe said so, an operator
  did it, or a sweeper decided the trial had run out — and `subscription_status`
  alone cannot tell those apart.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Audit, Billing, Repo}

  defp customer_user do
    user = insert_verified_user()
    Repo.update!(Ecto.Changeset.change(user, stripe_customer_id: "cus_audit123"))
  end

  defp billing_events(user_id) do
    user_id
    |> Audit.list_recent_for_user(100)
    |> Enum.filter(&String.starts_with?(&1.action, "billing."))
  end

  defp find_action(user_id, action) do
    Enum.find(billing_events(user_id), &(&1.action == action))
  end

  describe "the webhook path" do
    test "a status change produces a row for the affected user" do
      # The acceptance criterion of #550.
      user = customer_user()

      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_audit123", status: "active", trial_end: nil}}
      }

      assert {:ok, updated} = Billing.sync_subscription(event)
      assert updated.subscription_status == "active"

      event = find_action(user.id, "billing.subscription.synced")
      assert event, "a webhook that changes subscription status must be audited"
      assert event.user_id == user.id
      assert event.resource_type == "subscription"
      assert event.actor == "system:webhook"
      assert event.metadata["source"] == "webhook"
      assert event.metadata["from_status"] == user.subscription_status
      assert event.metadata["to_status"] == "active"
      assert event.metadata["event_type"] == "customer.subscription.updated"
    end

    test "a cancellation is recorded with both ends of the transition" do
      user = customer_user()

      {:ok, _} =
        Billing.sync_subscription(%Stripe.Event{
          type: "customer.subscription.updated",
          data: %{object: %{customer: "cus_audit123", status: "active", trial_end: nil}}
        })

      {:ok, _} =
        Billing.sync_subscription(%Stripe.Event{
          type: "customer.subscription.deleted",
          data: %{object: %{customer: "cus_audit123", status: "active", trial_end: nil}}
        })

      cancelled =
        billing_events(user.id)
        |> Enum.find(&(&1.metadata["to_status"] == "canceled"))

      assert cancelled, "a cancellation is the change a user is most likely to ask about"
      assert cancelled.metadata["from_status"] == "active"
    end

    test "a sync that changes nothing records nothing" do
      # The webhook path re-syncs constantly; a row per no-op would bury the
      # transitions that matter.
      user = customer_user()

      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{customer: "cus_audit123", status: "active", trial_end: nil}}
      }

      assert {:ok, _} = Billing.sync_subscription(event)
      before = length(billing_events(user.id))

      assert {:ok, _} = Billing.sync_subscription(event)
      assert length(billing_events(user.id)) == before
    end
  end

  describe "operator levers" do
    test "comping and un-comping are attributed to an admin" do
      user = customer_user()
      stub(Stripe.Subscription, :list, fn _params -> {:ok, %{data: []}} end)

      {:ok, _} = Billing.comp_account(user)
      comped = find_action(user.id, "billing.comped")
      assert comped.metadata["to_status"] == "comped"
      assert comped.metadata["source"] == "admin"

      # `admin`, not `system:admin`: an operator comping an account is a
      # person, and the vocabulary reserves `system:` for unattended paths
      # (ADR 0013). The source stays in metadata regardless.
      assert comped.actor == "admin"

      {:ok, comped_user} = {:ok, Repo.reload!(user)}
      {:ok, _} = Billing.revoke_comp(comped_user)

      revoked = find_action(user.id, "billing.comp_revoked")
      assert revoked.metadata["from_status"] == "comped"
      assert revoked.metadata["to_status"] == "canceled"
    end

    test "extending a trial records how long by" do
      user = customer_user()
      # `push_stripe_trial_end/2` lists first and only updates if it finds a
      # trialing subscription; an empty list short-circuits to :ok.
      stub(Stripe.Subscription, :list, fn _params -> {:ok, %{data: []}} end)

      {:ok, _} = Billing.extend_trial(user, 7)

      event = find_action(user.id, "billing.trial.extended")
      assert event.metadata["days"] == 7
      assert event.metadata["source"] == "admin"
    end
  end

  describe "attribution" do
    test "the source distinguishes who moved the account" do
      # Two accounts reaching "canceled" by different routes must be
      # distinguishable in the trail — that is the whole reason source exists.
      webhook_user = customer_user()

      {:ok, _} =
        Billing.sync_subscription(%Stripe.Event{
          type: "customer.subscription.deleted",
          data: %{object: %{customer: "cus_audit123", status: "canceled", trial_end: nil}}
        })

      assert find_action(webhook_user.id, "billing.subscription.synced").actor ==
               "system:webhook"
    end

    test "an operator-driven transition is not disguised as a system one" do
      # The two routes to the same status must not both read `system:`, or the
      # actor column stops answering "was a person behind this?".
      user = customer_user()
      stub(Stripe.Subscription, :list, fn _params -> {:ok, %{data: []}} end)

      {:ok, _} = Billing.extend_trial(user, 7)

      event = find_action(user.id, "billing.trial.extended")
      assert event.actor == "admin"
      assert event.metadata["source"] == "admin"
    end
  end
end
