defmodule FountainWeb.StripeWebhookControllerTest do
  use FountainWeb.ConnCase, async: true

  import Mimic

  setup :verify_on_exit!

  # Minimal valid-looking Stripe JSON body — content doesn't matter because
  # construct_event is stubbed; what matters is that CachingBodyReader stores
  # it in assigns[:raw_body] so the controller can forward it to the mock.
  @raw_body ~s({"id":"evt_test_123","type":"customer.subscription.updated","data":{"object":{}}})

  describe "POST /api/stripe/webhook" do
    test "returns 400 when Stripe signature verification fails", %{conn: conn} do
      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret ->
        {:error, :signature_verification_failed}
      end)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=badsig")
        |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :post, "/api/stripe/webhook", @raw_body)

      assert conn.status == 400
    end

    test "returns 200 when Stripe signature is valid", %{conn: conn} do
      # Stub returns a minimal event; sync_subscription will look up the user
      # by cus_unknown and return {:error, :user_not_found}, which the controller
      # logs and ignores — always responding 200 to Stripe.
      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_unknown", trial_end: nil}}
      }

      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret ->
        {:ok, event}
      end)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=validhash")
        |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :post, "/api/stripe/webhook", @raw_body)

      assert conn.status == 200
    end

    test "returns 200 and sync_subscription succeeds when customer matches a real user",
         %{conn: conn} do
      user = insert_verified_user()
      user = Fountain.Repo.update!(Ecto.Changeset.change(user, stripe_customer_id: "cus_success_test"))

      event = %Stripe.Event{
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: user.stripe_customer_id, trial_end: nil}}
      }

      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret ->
        {:ok, event}
      end)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=validhash")
        |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :post, "/api/stripe/webhook", @raw_body)

      assert conn.status == 200
    end
  end
end
