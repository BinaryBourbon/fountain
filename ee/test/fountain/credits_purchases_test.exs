defmodule Fountain.Credits.PurchasesTest do
  @moduledoc """
  Buying a pack and taking it back (ADR 0030 decision 5). What is pinned:
  who may buy, that the grant lands once per session however many times
  Stripe delivers it, that refunds are cumulative and partial, and that a
  clawback may go below zero.
  """

  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Accounts.User
  alias Fountain.Billing
  alias Fountain.Credits
  alias Fountain.Credits.Purchases
  alias Fountain.Repo

  @return "https://fountain.test/account/billing"

  defp with_status(user, _status) do
    {:ok, user} =
      user
      |> User.billing_changeset(%{stripe_customer_id: "cus_#{user.id}"})
      |> Repo.update()

    user
  end

  defp session(user, cents, opts \\ []) do
    %{
      id: Keyword.get(opts, :id, "cs_test_1"),
      mode: "payment",
      customer: user.stripe_customer_id,
      client_reference_id: user.id,
      payment_intent: Keyword.get(opts, :pi, "pi_1"),
      amount_total: cents,
      metadata: %{
        "fountain_credits_cents" => Integer.to_string(cents),
        "fountain_user_id" => user.id
      }
    }
  end

  describe "checkout_url/3" do
    test "opens a payment-mode session for a pack, with the pack in the metadata" do
      user = insert_empty_user() |> with_status("active")
      test = self()

      expect(Stripe.Checkout.Session, :create, fn params ->
        send(test, {:params, params})
        {:ok, %Stripe.Checkout.Session{url: "https://checkout.stripe.com/x"}}
      end)

      assert {:ok, "https://checkout.stripe.com/x"} = Purchases.checkout_url(user, 2500, @return)
      assert_receive {:params, params}
      assert params.mode == :payment

      assert [%{price_data: %{unit_amount: 2500, currency: "usd"}, quantity: 1}] =
               params.line_items

      assert params.metadata["fountain_credits_cents"] == "2500"
      assert params.payment_intent_data.metadata["fountain_credits_cents"] == "2500"
      assert params.customer == user.stripe_customer_id
      assert params.client_reference_id == user.id
      assert params.success_url == @return <> "?credits=success"
    end

    test "a comped account has nothing to buy, and only packs sell" do
      reject(&Stripe.Checkout.Session.create/1)

      comped = insert_empty_user()
      {:ok, comped} = Billing.comp_account(comped)
      assert {:error, :comped} = Purchases.checkout_url(comped, 1000, @return)

      active = insert_empty_user() |> with_status("active")
      assert {:error, :unknown_pack} = Purchases.checkout_url(active, 1234, @return)
    end
  end

  describe "complete/1" do
    test "grants the pack once, keyed by the session, with the payment intent on the row" do
      user = insert_empty_user() |> with_status("active")
      s = session(user, 2500)

      assert {:ok, entry} = Purchases.complete(s)
      assert entry.reason == "purchase"
      assert entry.amount_cents == 2500
      assert entry.idempotency_key == "purchase:cs_test_1"
      assert entry.metadata["payment_intent"] == "pi_1"
      assert is_nil(entry.expires_at)

      assert {:ok, :duplicate, ^entry} = Purchases.complete(s)
      assert Credits.balance(user.id) == 2500
    end

    test "a subscription-mode session is not ours" do
      user = insert_empty_user() |> with_status("active")

      assert {:error, :not_credits} =
               Purchases.complete(%{
                 id: "cs_sub",
                 mode: "subscription",
                 customer: user.stripe_customer_id,
                 metadata: %{}
               })

      assert {:error, :user_not_found} =
               Purchases.complete(%{
                 session(user, 1000)
                 | customer: "cus_nobody",
                   client_reference_id: nil,
                   metadata: %{"fountain_credits_cents" => "1000"}
               })
    end
  end

  describe "refund/1 and dispute/1" do
    setup do
      user = insert_empty_user() |> with_status("active")
      {:ok, _} = Purchases.complete(session(user, 2500))
      %{user: user}
    end

    test "a partial refund claws back the delta, cumulatively, once per amount", %{user: user} do
      charge = %{id: "ch_1", payment_intent: "pi_1", amount_refunded: 1000}
      assert {:ok, entry} = Purchases.refund(charge)
      assert entry.amount_cents == -1000
      assert entry.idempotency_key == "clawback_refund:ch_1:1000"
      assert Credits.balance(user.id) == 1500

      # Redelivered: the cumulative amount is already clawed back, nothing new.
      assert {:ok, :nothing} = Purchases.refund(charge)
      assert Credits.balance(user.id) == 1500

      # The rest is refunded: Stripe reports the cumulative 2500.
      assert {:ok, entry} = Purchases.refund(%{charge | amount_refunded: 2500})
      assert entry.amount_cents == -1500
      assert Credits.balance(user.id) == 0
    end

    test "a refund of a spent pack goes below zero", %{user: user} do
      {:ok, _} = Credits.debit(user.id, 2000, "burn_turn", idempotency_key: "spent")

      assert {:ok, _} =
               Purchases.refund(%{id: "ch_1", payment_intent: "pi_1", amount_refunded: 2500})

      assert Credits.balance(user.id) == -2000
    end

    test "a charge that is not a credits purchase is nothing to us" do
      assert {:ok, :nothing} =
               Purchases.refund(%{id: "ch_x", payment_intent: "pi_other", amount_refunded: 500})

      assert {:ok, :nothing} =
               Purchases.refund(%{id: "ch_y", payment_intent: nil, amount_refunded: 500})
    end

    test "a dispute claws back its amount once", %{user: user} do
      d = %{
        id: "dp_1",
        charge: "ch_1",
        payment_intent: "pi_1",
        amount: 2500,
        reason: "fraudulent"
      }

      assert {:ok, entry} = Purchases.dispute(d)
      assert entry.reason == "clawback_dispute"
      assert entry.metadata["reason"] == "fraudulent"
      assert {:ok, :duplicate, _} = Purchases.dispute(d)
      assert Credits.balance(user.id) == 0
      assert {:ok, :nothing} = Purchases.dispute(%{d | payment_intent: "pi_other"})
    end
  end

  describe "through the webhook" do
    test "checkout.session.completed in payment mode grants; refund and dispute claw back", %{} do
      user = insert_empty_user() |> with_status("active")

      grant = %Stripe.Event{
        id: "evt_credits_1",
        type: "checkout.session.completed",
        created: DateTime.utc_now() |> DateTime.to_unix(),
        data: %{object: session(user, 1000, id: "cs_hook")}
      }

      assert {:ok, :credits_purchased} = Billing.handle_event(grant)
      assert {:ok, :duplicate} = Billing.handle_event(grant)
      assert Credits.balance(user.id) == 1000

      refund = %Stripe.Event{
        id: "evt_refund_1",
        type: "charge.refunded",
        created: DateTime.utc_now() |> DateTime.to_unix(),
        data: %{object: %{id: "ch_hook", payment_intent: "pi_1", amount_refunded: 400}}
      }

      assert {:ok, :credits_clawed_back} = Billing.handle_event(refund)
      assert Credits.balance(user.id) == 600

      dispute = %Stripe.Event{
        id: "evt_dispute_1",
        type: "charge.dispute.created",
        created: DateTime.utc_now() |> DateTime.to_unix(),
        data: %{object: %{id: "dp_hook", charge: "ch_hook", payment_intent: "pi_1", amount: 600}}
      }

      assert {:ok, :credits_clawed_back} = Billing.handle_event(dispute)
      assert Credits.balance(user.id) == 0

      # Not a credits charge: acknowledged, ignored.
      other = %{
        refund
        | id: "evt_refund_2",
          data: %{object: %{id: "ch_o", payment_intent: "pi_sub", amount_refunded: 1}}
      }

      assert {:ok, :ignored} = Billing.handle_event(other)
    end

    test "a subscription checkout is ignored" do
      user = insert_empty_user()

      event = %Stripe.Event{
        type: "checkout.session.completed",
        data: %{
          object: %{
            customer: "cus_orphan",
            client_reference_id: user.id,
            mode: "subscription",
            metadata: %{}
          }
        }
      }

      # ADR 0031: not ours, acknowledged and ignored; nothing is written.
      assert {:ok, :ignored} = Billing.sync_subscription(event)
      assert Credits.balance(user.id) == 0
      assert Repo.reload!(user).stripe_customer_id == nil
    end
  end
end
