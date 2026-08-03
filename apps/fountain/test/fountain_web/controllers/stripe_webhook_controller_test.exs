defmodule FountainWeb.StripeWebhookControllerTest do
  use FountainWeb.ConnCase, async: true

  import Mimic

  setup :verify_on_exit!

  # Minimal valid-looking Stripe JSON body — content doesn't matter because
  # construct_event is stubbed; what matters is that CachingBodyReader stores
  # it in assigns[:raw_body] so the controller can forward it to the mock.
  @raw_body ~s({"id":"evt_test_123","type":"customer.subscription.updated","data":{"object":{}}})

  # A complete event body for the tests that exercise the REAL
  # Stripe.Webhook.construct_event/3 — no stubbing, so the payload has to
  # survive Stripe.Converter and the signature has to be genuine.
  @signed_body ~s({"id":"evt_real_sig_test","object":"event","api_version":"2019-12-03",) <>
                 ~s("type":"customer.subscription.updated",) <>
                 ~s("data":{"object":{"id":"sub_real_sig_test","object":"subscription",) <>
                 ~s("status":"active","customer":"cus_real_sig_unknown","trial_end":null}}})

  defp stripe_signature(payload, secret, timestamp \\ System.system_time(:second)) do
    signature =
      :crypto.mac(:hmac, :sha256, secret, "#{timestamp}.#{payload}")
      |> Base.encode16(case: :lower)

    "t=#{timestamp},v1=#{signature}"
  end

  defp post_webhook(conn, body, sig_header) do
    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("stripe-signature", sig_header)
    |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :post, "/api/stripe/webhook", body)
  end

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

      # The 200 alone is vacuous — the controller 200s on every handle_event
      # outcome (#337). The state change is the assertion that can fail when
      # the apply path breaks.
      assert Fountain.Repo.get!(Fountain.Accounts.User, user.id).subscription_status ==
               "active"
    end
  end

  describe "POST /api/stripe/webhook — real signature verification (no stub)" do
    # These exercise the controller's secret resolution end to end. The
    # pre-#390 code resolved the secret from an app-env key nothing sets and
    # fell back to "", so it was never covered: every earlier test handed a
    # stubbed construct_event whatever secret happened to resolve.

    test "accepts a payload genuinely signed with the configured secret", %{conn: conn} do
      secret = Application.fetch_env!(:stripity_stripe, :webhook_secret)
      conn = post_webhook(conn, @signed_body, stripe_signature(@signed_body, secret))

      # cus_real_sig_unknown matches no user; the controller logs and acks.
      # What matters is that verification passed — a signature failure or a
      # missing secret would be 400.
      assert conn.status == 200
    end

    test "rejects a payload signed with an empty key", %{conn: conn} do
      # The forgery #390 describes: with the secret unset, the old code
      # verified against "", so exactly this request was accepted.
      conn = post_webhook(conn, @signed_body, stripe_signature(@signed_body, ""))

      assert conn.status == 400
    end

    test "rejects a payload signed with the wrong secret", %{conn: conn} do
      conn = post_webhook(conn, @signed_body, stripe_signature(@signed_body, "whsec_other"))

      assert conn.status == 400
    end
  end
end
