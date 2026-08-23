defmodule Fountain.BillingPlansTest do
  @moduledoc """
  Plans, as billing sees them: which price a signup opens on, what a webhook
  writes to `users.plan`, what a tier switch asks Stripe for, and how the
  teammate-contact add-on quantity is kept honest.
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

  describe "sync_contact_addon/1" do
    setup do
      user = subscribed("cus_addon", "sub_addon", "team")
      agent = insert_agent(user_id: user.id)
      {:ok, user: user, agent: agent}
    end

    test "adds the item at the contact count when there is none", %{user: user, agent: agent} do
      insert_contact(user, agent)

      stub(Stripe.Subscription, :retrieve, fn "sub_addon" ->
        {:ok, %{id: "sub_addon", items: %{data: [%{id: "si_plan", price: %{id: "price_team"}}]}}}
      end)

      expect(Stripe.SubscriptionItem, :create, fn params ->
        assert params.subscription == "sub_addon"
        assert params.price == "price_contact"
        assert params.quantity == 1
        {:ok, %{id: "si_addon"}}
      end)

      assert {:ok, 1} = Billing.sync_contact_addon(user.id)
    end

    # Set, never increment: a dropped call, a retry or an admin deleting rows
    # all converge on the right number the next time this runs.
    test "sets the quantity from the rows, not from a delta", %{user: user, agent: agent} do
      insert_contact(user, agent)
      insert_contact(user, insert_agent(user_id: user.id))
      insert_contact(user, insert_agent(user_id: user.id))

      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok,
         %{
           id: "sub_addon",
           items: %{
             data: [
               %{id: "si_plan", price: %{id: "price_team"}},
               %{id: "si_addon", price: %{id: "price_contact"}, quantity: 1}
             ]
           }
         }}
      end)

      expect(Stripe.SubscriptionItem, :update, fn "si_addon", params ->
        assert params.quantity == 3
        {:ok, %{id: "si_addon"}}
      end)

      assert {:ok, 3} = Billing.sync_contact_addon(user.id)
    end

    # Stripe rejects a zero quantity on a licensed price, and a lingering item
    # puts "1 x contact" on the invoice of a tenant with no numbers left.
    test "deletes the item when the last contact goes", %{user: user} do
      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok,
         %{
           id: "sub_addon",
           items: %{data: [%{id: "si_addon", price: %{id: "price_contact"}, quantity: 2}]}
         }}
      end)

      expect(Stripe.SubscriptionItem, :delete, fn "si_addon", _params ->
        {:ok, %{id: "si_addon"}}
      end)

      assert {:ok, 0} = Billing.sync_contact_addon(user.id)
    end

    test "does nothing when the quantity already matches", %{user: user, agent: agent} do
      insert_contact(user, agent)

      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok,
         %{
           id: "sub_addon",
           items: %{data: [%{id: "si_addon", price: %{id: "price_contact"}, quantity: 1}]}
         }}
      end)

      reject(&Stripe.SubscriptionItem.update/2)
      assert {:ok, 1} = Billing.sync_contact_addon(user.id)
    end

    # The common case for every tenant that has never used teammate comms.
    # A zero-quantity item would put a $0 line on every invoice for no reason.
    test "adds no item for a tenant with no contacts", %{user: user} do
      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok, %{id: "sub_addon", items: %{data: [%{id: "si_plan", price: %{id: "price_team"}}]}}}
      end)

      reject(&Stripe.SubscriptionItem.create/1)
      assert {:ok, 0} = Billing.sync_contact_addon(user.id)
    end

    test "bills nothing when no contact price is configured", %{user: user} do
      Application.put_env(:fountain, :stripe_price_ids, Map.delete(@price_ids, "contact"))
      reject(&Stripe.Subscription.retrieve/1)

      assert {:ok, :not_billed} = Billing.sync_contact_addon(user.id)
    end

    # The narrow lever: pays for the tier, holds a number Fountain eats.
    # `comped` on the account is the broad one and short-circuits entirely.
    test "the comped allowance comes off the billed quantity", %{user: user, agent: agent} do
      insert_contact(user, agent)
      insert_contact(user, insert_agent(user_id: user.id))
      insert_contact(user, insert_agent(user_id: user.id))
      {:ok, user} = Fountain.Accounts.update_comped_contacts(user, 1)

      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok,
         %{
           id: "sub_addon",
           items: %{data: [%{id: "si_addon", price: %{id: "price_contact"}, quantity: 3}]}
         }}
      end)

      expect(Stripe.SubscriptionItem, :update, fn "si_addon", params ->
        assert params.quantity == 2
        {:ok, %{id: "si_addon"}}
      end)

      assert {:ok, 2} = Billing.sync_contact_addon(user.id)
    end

    # Jake's case: pays for the plan, one free number. Stripe must be billed
    # for nothing, and the item deleted rather than set to a zero quantity a
    # licensed price rejects.
    test "an allowance covering every contact bills nothing", %{user: user, agent: agent} do
      insert_contact(user, agent)
      {:ok, user} = Fountain.Accounts.update_comped_contacts(user, 1)

      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:ok,
         %{
           id: "sub_addon",
           items: %{data: [%{id: "si_addon", price: %{id: "price_contact"}, quantity: 1}]}
         }}
      end)

      expect(Stripe.SubscriptionItem, :delete, fn "si_addon", _ -> {:ok, %{id: "si_addon"}} end)

      assert {:ok, 0} = Billing.sync_contact_addon(user.id)
    end

    # An allowance bigger than the contact count must floor at zero, not hand
    # Stripe a negative quantity.
    test "an allowance larger than the count floors at zero", %{user: user, agent: agent} do
      insert_contact(user, agent)
      {:ok, user} = Fountain.Accounts.update_comped_contacts(user, 10)

      assert Billing.billable_contacts(Repo.get!(User, user.id)) == 0
    end

    test "bills nothing for a comped account or one with no subscription", %{user: user} do
      {:ok, comped} =
        user |> Ecto.Changeset.change(subscription_status: "comped") |> Repo.update()

      reject(&Stripe.Subscription.retrieve/1)

      assert {:ok, :not_billed} = Billing.sync_contact_addon(comped.id)
      assert {:ok, :not_billed} = Billing.sync_contact_addon(insert_verified_user().id)
    end
  end

  # The add-on item lives on the subscription, so a *new* subscription starts
  # without it — and the quantity is otherwise only pushed on provision and
  # release. Left unfixed, an account that cancelled (or was comped and then
  # un-comped) and came back through Checkout kept its numbers and stopped
  # being billed for them until it happened to add or remove one.
  describe "a resubscription re-attaches the contact add-on" do
    setup do
      user = customer("cus_resub")
      agent = insert_agent(user_id: user.id)
      {:ok, user: user, agent: agent}
    end

    test "the new subscription gets an item at the contact count", %{user: user, agent: agent} do
      insert_contact(user, agent)
      test_pid = self()

      stub(Stripe.Subscription, :retrieve, fn "sub_new" ->
        {:ok, %{id: "sub_new", items: %{data: [%{id: "si_plan", price: %{id: "price_solo"}}]}}}
      end)

      expect(Stripe.SubscriptionItem, :create, fn params ->
        send(test_pid, {:addon_created, params.subscription, params.quantity})
        {:ok, %{id: "si_addon"}}
      end)

      assert {:ok, _} = checkout_completed(user, "cus_resub", "sub_new")
      assert_received {:addon_created, "sub_new", 1}
      assert Repo.get!(User, user.id).stripe_subscription_id == "sub_new"
    end

    test "a tenant with no contacts gets no item and no Stripe call", %{user: user} do
      reject(&Stripe.Subscription.retrieve/1)
      reject(&Stripe.SubscriptionItem.create/1)

      assert {:ok, _} = checkout_completed(user, "cus_resub", "sub_new2")
      assert Repo.get!(User, user.id).stripe_subscription_id == "sub_new2"
    end

    # The adoption is the event's job. A Stripe hiccup re-attaching the add-on
    # must not make the webhook fail and have Stripe redeliver an adoption
    # that already succeeded.
    test "a failure to re-attach does not fail the adoption", %{user: user, agent: agent} do
      insert_contact(user, agent)

      stub(Stripe.Subscription, :retrieve, fn _ ->
        {:error,
         %Stripe.Error{
           source: :network,
           code: :api_connection_error,
           message: "down"
         }}
      end)

      assert {:ok, _} = checkout_completed(user, "cus_resub", "sub_new3")
      assert Repo.get!(User, user.id).stripe_subscription_id == "sub_new3"
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
