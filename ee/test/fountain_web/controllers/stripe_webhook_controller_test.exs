defmodule FountainWeb.StripeWebhookControllerTest do
  use FountainWeb.ConnCase, async: true

  import Ecto.Query
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
        |> Phoenix.ConnTest.dispatch(
          FountainWeb.Endpoint,
          :post,
          "/api/stripe/webhook",
          @raw_body
        )

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
        |> Phoenix.ConnTest.dispatch(
          FountainWeb.Endpoint,
          :post,
          "/api/stripe/webhook",
          @raw_body
        )

      assert conn.status == 200
    end

    test "returns 200 and sync_subscription succeeds when customer matches a real user",
         %{conn: conn} do
      user = insert_verified_user()

      user =
        Fountain.Repo.update!(Ecto.Changeset.change(user, stripe_customer_id: "cus_success_test"))

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
        |> Phoenix.ConnTest.dispatch(
          FountainWeb.Endpoint,
          :post,
          "/api/stripe/webhook",
          @raw_body
        )

      assert conn.status == 200

      # The 200 alone is vacuous — the controller 200s on every handle_event
      # outcome (#337). The state change is the assertion that can fail when
      # the apply path breaks.
      assert Fountain.Repo.get!(Fountain.Accounts.User, user.id).subscription_status ==
               "active"
    end

    # The :retry/500 arm (#337 gave every outcome a 200; #414 flagged that the
    # 500 path had no controller test). 500 is the only thing that makes
    # Stripe redeliver, so these are the tests that fail if someone
    # "simplifies" the controller back to always-200.
    @tag capture_log: true
    test "returns 500 so Stripe redelivers when processing fails transiently", %{conn: conn} do
      event = %Stripe.Event{
        id: "evt_retry_test",
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_x", trial_end: nil}}
      }

      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret -> {:ok, event} end)
      stub(Fountain.Billing, :handle_event, fn _event -> {:error, :database_unavailable} end)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=validhash")
        |> Phoenix.ConnTest.dispatch(
          FountainWeb.Endpoint,
          :post,
          "/api/stripe/webhook",
          @raw_body
        )

      assert conn.status == 500
    end

    @tag capture_log: true
    test "returns 500 when processing raises (rescue funnels into :retry)", %{conn: conn} do
      event = %Stripe.Event{
        id: "evt_raise_test",
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_x", trial_end: nil}}
      }

      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret -> {:ok, event} end)
      stub(Fountain.Billing, :handle_event, fn _event -> raise "boom mid-processing" end)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=validhash")
        |> Phoenix.ConnTest.dispatch(
          FountainWeb.Endpoint,
          :post,
          "/api/stripe/webhook",
          @raw_body
        )

      assert conn.status == 500
    end

    @tag capture_log: true
    test "still acks with 200 when the customer is unknown — retrying cannot fix it",
         %{conn: conn} do
      # The one error branch that deliberately answers 200: user_not_found.
      # Kept next to the 500 tests so the asymmetry is visible in one place.
      event = %Stripe.Event{
        id: "evt_unknown_customer",
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_nobody", trial_end: nil}}
      }

      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret -> {:ok, event} end)
      stub(Fountain.Billing, :handle_event, fn _event -> {:error, :user_not_found} end)

      conn =
        conn
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=validhash")
        |> Phoenix.ConnTest.dispatch(
          FountainWeb.Endpoint,
          :post,
          "/api/stripe/webhook",
          @raw_body
        )

      assert conn.status == 200
    end
  end

  describe "POST /api/stripe/webhook — failure persistence (#501)" do
    defp failure_row(event_id) do
      Fountain.Repo.one(
        from f in "stripe_webhook_failures",
          where: f.event_id == ^event_id,
          select: %{
            type: f.event_type,
            error: f.error,
            count: f.failure_count,
            resolved_at: f.resolved_at
          }
      )
    end

    defp post_stubbed(conn, event) do
      stub(Stripe.Webhook, :construct_event, fn _body, _sig, _secret -> {:ok, event} end)

      conn
      |> Plug.Conn.put_req_header("content-type", "application/json")
      |> Plug.Conn.put_req_header("stripe-signature", "t=1,v1=validhash")
      |> Phoenix.ConnTest.dispatch(FountainWeb.Endpoint, :post, "/api/stripe/webhook", @raw_body)
    end

    @tag capture_log: true
    test "a transient failure persists a row; a retried failure bumps the count", %{conn: conn} do
      event = %Stripe.Event{
        id: "evt_fail_persist",
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_x", trial_end: nil}}
      }

      stub(Fountain.Billing, :handle_event, fn _event -> {:error, :database_unavailable} end)

      assert post_stubbed(conn, event).status == 500

      row = failure_row("evt_fail_persist")
      assert %{count: 1, resolved_at: nil, type: "customer.subscription.updated"} = row
      assert row.error =~ "database_unavailable"

      assert post_stubbed(conn, event).status == 500
      assert %{count: 2, resolved_at: nil} = failure_row("evt_fail_persist")
    end

    @tag capture_log: true
    test "an unknown customer is acked to Stripe but recorded — the event is gone for good",
         %{conn: conn} do
      event = %Stripe.Event{
        id: "evt_fail_nobody",
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_nobody", trial_end: nil}}
      }

      assert post_stubbed(conn, event).status == 200

      row = failure_row("evt_fail_nobody")
      assert %{count: 1, resolved_at: nil} = row
      assert row.error =~ "user_not_found"
    end

    @tag capture_log: true
    test "a later successful delivery marks the failure resolved", %{conn: conn} do
      event = %Stripe.Event{
        id: "evt_fail_recovers",
        type: "customer.subscription.updated",
        data: %{object: %{status: "active", customer: "cus_x", trial_end: nil}}
      }

      stub(Fountain.Billing, :handle_event, fn _event -> {:error, :database_unavailable} end)
      assert post_stubbed(conn, event).status == 500
      assert %{resolved_at: nil} = failure_row("evt_fail_recovers")

      stub(Fountain.Billing, :handle_event, fn _event -> {:ok, :ignored} end)
      assert post_stubbed(conn, event).status == 200
      refute failure_row("evt_fail_recovers").resolved_at == nil
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
