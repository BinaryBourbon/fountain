defmodule Fountain.BillingPlansTest do
  @moduledoc """
  Plans, as billing sees them: which price a signup opens on, what a webhook
  writes to `users.plan`, what a tier switch asks Stripe for, and how the
  plan item is found among the subscription's items.
  """
  # async: false — these tests move :stripe_price_ids, which every other
  # billing test reads through Fountain.Plans.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Repo

  @price_ids %{
    "solo" => "price_solo",
    "team" => "price_team",
    "scale" => "price_scale",
    "contact" => "price_contact"
  }

  setup do
    price_ids = Application.get_env(:fountain, :stripe_price_ids)
    legacy = Application.get_env(:fountain, :stripe_price_id)

    Application.put_env(:fountain, :stripe_price_ids, @price_ids)
    Application.put_env(:fountain, :stripe_price_id, "price_legacy")

    on_exit(fn ->
      Application.put_env(:fountain, :stripe_price_ids, price_ids)
      Application.put_env(:fountain, :stripe_price_id, legacy)
    end)

    :ok
  end

  describe "available_plans/0" do
    test "offers only the public plans that have a price on this deployment" do
      Application.put_env(:fountain, :stripe_price_ids, %{"team" => "price_team"})

      assert Enum.map(Billing.available_plans(), & &1.slug) == ["team"]
    end

    # A tier with no price is not a cheaper tier, it is a button that leads to
    # a Stripe error.
    test "offers nothing when no price is configured" do
      Application.put_env(:fountain, :stripe_price_ids, %{})

      assert Billing.available_plans() == []
    end

    test "never offers the closed legacy plan, even with its price set" do
      refute Enum.any?(Billing.available_plans(), &(&1.slug == "legacy"))
    end

    test "offers nothing when billing is disabled" do
      Application.put_env(:fountain, :billing_enabled, false)
      on_exit(fn -> Application.put_env(:fountain, :billing_enabled, true) end)

      assert Billing.available_plans() == []
    end
  end

  describe "start_trial_subscription/1" do
    test "opens the trial on the default plan's price and stamps the slug" do
      user = customer("cus_trial")

      expect(Stripe.Subscription, :create, fn params, _opts ->
        assert [%{price: "price_solo"}] = params.items
        {:ok, %Stripe.Subscription{id: "sub_1", status: "trialing", trial_end: nil}}
      end)

      assert {:ok, updated} = Billing.start_trial_subscription(user)
      assert updated.plan == "solo"
    end

    test "follows DEFAULT_PLAN" do
      Application.put_env(:fountain, :default_plan, "scale")
      on_exit(fn -> Application.delete_env(:fountain, :default_plan) end)

      user = customer("cus_scale")

      expect(Stripe.Subscription, :create, fn params, _opts ->
        assert [%{price: "price_scale"}] = params.items
        {:ok, %Stripe.Subscription{id: "sub_2", status: "trialing", trial_end: nil}}
      end)

      assert {:ok, updated} = Billing.start_trial_subscription(user)
      assert updated.plan == "scale"
    end

    # The window between deploying the tiers and finishing the Stripe setup.
    # An unattended overnight signup lands here, and it must still get a
    # subscription rather than a silently free account.
    test "falls back to the old flat price when the default plan has none" do
      Application.put_env(:fountain, :stripe_price_ids, %{})
      user = customer("cus_fallback")

      expect(Stripe.Subscription, :create, fn params, _opts ->
        assert [%{price: "price_legacy"}] = params.items
        {:ok, %Stripe.Subscription{id: "sub_3", status: "trialing", trial_end: nil}}
      end)

      assert {:ok, updated} = Billing.start_trial_subscription(user)
      assert updated.plan == "legacy"
    end

    test "with no price at all, records a local trial and no subscription" do
      Application.put_env(:fountain, :stripe_price_ids, %{})
      Application.put_env(:fountain, :stripe_price_id, nil)

      user = customer("cus_none")
      reject(&Stripe.Subscription.create/2)

      assert {:ok, updated} = Billing.start_trial_subscription(user)
      assert updated.stripe_subscription_id == nil
      assert updated.plan == nil
    end
  end

  describe "plan_slug_from_subscription/1" do
    test "reads the plan item's price, whatever shape Stripe hands back" do
      assert Billing.plan_slug_from_subscription(%{
               items: %{data: [%{price: %{id: "price_team"}}]}
             }) == "team"

      assert Billing.plan_slug_from_subscription(%{
               "items" => %{"data" => [%{"price" => %{"id" => "price_scale"}}]}
             }) == "scale"
    end

    # A tenant with teammate contacts carries two items. Order must not decide
    # the answer, and the add-on must never be mistaken for a tier.
    test "ignores the contact add-on item, in either position" do
      addon = %{price: %{id: "price_contact"}}
      plan = %{price: %{id: "price_solo"}}

      assert Billing.plan_slug_from_subscription(%{items: %{data: [addon, plan]}}) == "solo"
      assert Billing.plan_slug_from_subscription(%{items: %{data: [plan, addon]}}) == "solo"
      assert Billing.plan_slug_from_subscription(%{items: %{data: [addon]}}) == nil
    end

    test "answers nil for a price this deployment does not know, and for no items" do
      assert Billing.plan_slug_from_subscription(%{items: %{data: [%{price: %{id: "price_x"}}]}}) ==
               nil

      assert Billing.plan_slug_from_subscription(%{}) == nil
    end
  end

  describe "sync_subscription/1 — the plan the webhook writes" do
    test "an update to a different price moves the plan" do
      user = subscribed("cus_up", "sub_up", "solo")

      assert {:ok, _} = sync(user, "sub_up", "price_team", "customer.subscription.updated")
      assert reload(user).plan == "team"
    end

    # An env var not yet set on the replica handling the webhook is the
    # realistic cause. Nulling a paying tenant's entitlement over it is worse
    # than leaving it stale.
    test "an unknown price leaves the stored plan alone" do
      user = subscribed("cus_unknown", "sub_unknown", "team")

      assert {:ok, _} =
               sync(user, "sub_unknown", "price_from_the_future", "customer.subscription.updated")

      assert reload(user).plan == "team"
    end

    # The plan a resubscription should default back to is the one they had.
    test "a deletion leaves the plan alone while the status changes" do
      user = subscribed("cus_del", "sub_del", "scale")

      assert {:ok, _} = sync(user, "sub_del", "price_solo", "customer.subscription.deleted")

      reloaded = reload(user)
      assert reloaded.plan == "scale"
      assert reloaded.subscription_status == "canceled"
    end

    test "a comped account ignores the event entirely" do
      user = subscribed("cus_comp", "sub_comp", "team")
      {:ok, user} = user |> Ecto.Changeset.change(subscription_status: "comped") |> Repo.update()

      assert {:ok, :comped_ignored} =
               sync(user, "sub_comp", "price_scale", "customer.subscription.updated")

      assert reload(user).plan == "team"
    end
  end

  describe "change_plan/3" do
    test "reprices the plan item and leaves the add-on item alone" do
      user = subscribed("cus_sw", "sub_sw", "solo")

      expect(Stripe.Subscription, :retrieve, fn "sub_sw" ->
        {:ok,
         %{
           id: "sub_sw",
           items: %{
             data: [
               %{id: "si_addon", price: %{id: "price_contact"}, quantity: 2},
               %{id: "si_plan", price: %{id: "price_solo"}, quantity: 1}
             ]
           }
         }}
      end)

      expect(Stripe.SubscriptionItem, :update, fn "si_plan", params ->
        assert params.price == "price_team"
        assert params.proration_behavior == :create_prorations
        {:ok, %{id: "si_plan"}}
      end)

      assert {:ok, _} = Billing.change_plan(user, "team")
    end

    # The local column is the webhook's to write, so the entitlement always
    # follows what Stripe actually charges rather than what we asked for.
    test "does not write the plan locally — the webhook does" do
      user = subscribed("cus_wait", "sub_wait", "solo")

      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok, %{id: "sub_wait", items: %{data: [%{id: "si", price: %{id: "price_solo"}}]}}}
      end)

      stub(Stripe.SubscriptionItem, :update, fn _, _ -> {:ok, %{id: "si"}} end)

      assert {:ok, _} = Billing.change_plan(user, "scale")
      assert reload(user).plan == "solo"
    end

    test "refuses a comped account" do
      user = subscribed("cus_c", "sub_c", "solo")
      {:ok, user} = user |> Ecto.Changeset.change(subscription_status: "comped") |> Repo.update()

      assert {:error, :comped} = Billing.change_plan(user, "team")
    end

    test "refuses an unknown or unpriced plan before calling Stripe" do
      user = subscribed("cus_u", "sub_u", "solo")
      reject(&Stripe.Subscription.retrieve/1)

      assert {:error, :unknown_plan} = Billing.change_plan(user, "enterprise")

      Application.put_env(:fountain, :stripe_price_ids, %{"solo" => "price_solo"})
      assert {:error, :plan_unavailable} = Billing.change_plan(user, "scale")
    end

    test "refuses when there is no subscription to reprice" do
      user = insert_verified_user()
      assert {:error, :no_subscription} = Billing.change_plan(user, "team")
    end

    test "refuses when the subscription carries no item it recognises" do
      user = subscribed("cus_ni", "sub_ni", "solo")

      expect(Stripe.Subscription, :retrieve, fn "sub_ni" ->
        {:ok, %{id: "sub_ni", items: %{data: [%{id: "si", price: %{id: "price_contact"}}]}}}
      end)

      assert {:error, :plan_item_not_found} = Billing.change_plan(user, "team")
    end
  end

  ## helpers

  defp checkout_completed(_user, customer_id, subscription_id) do
    Billing.sync_subscription(%Stripe.Event{
      id: "evt_#{System.unique_integer([:positive])}",
      type: "checkout.session.completed",
      created: DateTime.utc_now() |> DateTime.to_unix(),
      data: %{
        object: %{
          customer: customer_id,
          subscription: subscription_id,
          client_reference_id: nil
        }
      }
    })
  end

  defp customer(id) do
    user = insert_verified_user()
    {:ok, user} = user |> User.billing_changeset(%{stripe_customer_id: id}) |> Repo.update()
    user
  end

  defp subscribed(customer_id, subscription_id, plan) do
    user = customer(customer_id)

    {:ok, user} =
      user
      |> User.billing_changeset(%{
        stripe_subscription_id: subscription_id,
        subscription_status: "active",
        plan: plan
      })
      |> Repo.update()

    user
  end

  defp insert_contact(user, agent) do
    %Fountain.Team.Contact{}
    |> Fountain.Team.Contact.changeset(%{
      user_id: user.id,
      agent_id: agent.id,
      email_address: "t#{System.unique_integer([:positive])}@example.com",
      email_inbox_id: "inbox_#{System.unique_integer([:positive])}",
      phone_number: "+15551230000",
      phone_number_id: "num_#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp sync(_user, subscription_id, price_id, type) do
    Billing.sync_subscription(%Stripe.Event{
      id: "evt_#{System.unique_integer([:positive])}",
      type: type,
      created: DateTime.utc_now() |> DateTime.to_unix(),
      data: %{
        object: %{
          id: subscription_id,
          customer: customer_of(subscription_id),
          status: "active",
          items: %{data: [%{id: "si", price: %{id: price_id}}]}
        }
      }
    })
  end

  defp customer_of("sub_up"), do: "cus_up"
  defp customer_of("sub_unknown"), do: "cus_unknown"
  defp customer_of("sub_del"), do: "cus_del"
  defp customer_of("sub_comp"), do: "cus_comp"

  defp reload(user), do: Repo.get!(User, user.id)
end
