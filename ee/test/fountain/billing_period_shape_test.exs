defmodule Fountain.BillingPeriodShapeTest do
  @moduledoc """
  The billing period as Stripe actually sends it today (#1018).

  Stripe moved `current_period_start`/`current_period_end` off the subscription
  and onto its items. Every other test in this suite hand-builds the *old*
  shape, so the fixture agreed with the code and both disagreed with Stripe —
  which is why `users.current_period_end` was null for every account in
  production and nobody noticed. These fixtures are built the new way on
  purpose.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Repo

  defp customer(id) do
    user = insert_verified_user()

    {:ok, user} =
      user
      |> User.billing_changeset(%{
        stripe_customer_id: id,
        stripe_subscription_id: "sub_#{id}",
        subscription_status: "active"
      })
      |> Repo.update()

    user
  end

  defp event(customer_id, object) do
    %Stripe.Event{
      id: "evt_#{System.unique_integer([:positive])}",
      type: "customer.subscription.updated",
      created: DateTime.utc_now() |> DateTime.to_unix(),
      data: %{
        object:
          Map.merge(
            %{
              id: "sub_#{customer_id}",
              customer: customer_id,
              status: "active",
              trial_end: nil,
              cancel_at_period_end: true
            },
            object
          )
      }
    }
  end

  describe "period_end_unix/1" do
    test "prefers the subscription-level field when Stripe still sends one" do
      assert Billing.period_end_unix(%{current_period_end: 1_800_000_000}) == 1_800_000_000
    end

    # The shape that broke it: null at the top, real value on the item.
    test "falls back to the item when the subscription-level field is null" do
      sub = %{
        current_period_end: nil,
        items: %{data: [%{id: "si_1", current_period_end: 1_789_036_174}]}
      }

      assert Billing.period_end_unix(sub) == 1_789_036_174
    end

    test "reads string keys too" do
      sub = %{"items" => %{"data" => [%{"current_period_end" => 1_789_036_174}]}}
      assert Billing.period_end_unix(sub) == 1_789_036_174
    end

    # A tenant with teammate contacts carries a plan item and an add-on item;
    # both ride the same subscription and share its period, so any item will do
    # — but it must not stop at an item that happens to carry no period.
    test "skips an item with no period and takes the one that has it" do
      sub = %{
        items: %{
          data: [
            %{id: "si_addon"},
            %{id: "si_plan", current_period_end: 1_789_036_174}
          ]
        }
      }

      assert Billing.period_end_unix(sub) == 1_789_036_174
    end

    test "answers nil when nothing carries a period" do
      assert Billing.period_end_unix(%{}) == nil
      assert Billing.period_end_unix(%{items: %{data: [%{id: "si_1"}]}}) == nil
    end
  end

  describe "sync_subscription/1 with the current Stripe shape" do
    # The end-to-end version of the bug: a cancelling customer is promised
    # "access until <date>", and the date came out blank.
    test "records the period end from the item" do
      user = customer("cus_shape")
      period_end = 1_789_036_174

      assert {:ok, updated} =
               Billing.sync_subscription(
                 event("cus_shape", %{
                   current_period_end: nil,
                   items: %{data: [%{id: "si_1", current_period_end: period_end}]}
                 })
               )

      assert updated.id == user.id
      assert updated.cancel_at_period_end
      assert updated.current_period_end == DateTime.from_unix!(period_end)
    end

    test "still records it from the old shape, so older API versions keep working" do
      _user = customer("cus_old")
      period_end = 1_800_000_000

      assert {:ok, updated} =
               Billing.sync_subscription(event("cus_old", %{current_period_end: period_end}))

      assert updated.current_period_end == DateTime.from_unix!(period_end)
    end

    test "a subscription carrying no period anywhere records nil rather than raising" do
      _user = customer("cus_none")

      assert {:ok, updated} =
               Billing.sync_subscription(event("cus_none", %{items: %{data: [%{id: "si_1"}]}}))

      assert updated.current_period_end == nil
    end
  end
end
