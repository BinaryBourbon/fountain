defmodule FountainWeb.StripeWebhookSecretTest do
  # async: false — these tests mutate the global :stripity_stripe application
  # env to simulate an instance where STRIPE_WEBHOOK_SECRET was never set.
  use FountainWeb.ConnCase, async: false

  # Regression tests for #390: with no webhook secret configured, the old
  # controller verified signatures against "" — a key anyone can compute
  # with — so a forged event reached Billing.handle_event/1 on any instance
  # (e.g. every self-hosted one) that never set STRIPE_WEBHOOK_SECRET.
  #
  # Per the audit lesson, the missing-secret cases must supply the empty
  # value as well as the absent one: `${VAR:-}`-style deployment plumbing
  # produces "", not nil, and "" is truthy.

  @signed_body ~s({"id":"evt_no_secret_test","object":"event","api_version":"2019-12-03",) <>
                 ~s("type":"customer.subscription.updated",) <>
                 ~s("data":{"object":{"id":"sub_no_secret_test","object":"subscription",) <>
                 ~s("status":"active","customer":"cus_no_secret_unknown","trial_end":null}}})

  setup do
    original = Application.fetch_env!(:stripity_stripe, :webhook_secret)
    on_exit(fn -> Application.put_env(:stripity_stripe, :webhook_secret, original) end)
    :ok
  end

  defp forge(conn, key) do
    # Exactly what an attacker sends: a fresh timestamp and a v1 signature
    # HMAC'd with the guessed key.
    timestamp = System.system_time(:second)

    signature =
      :crypto.mac(:hmac, :sha256, key, "#{timestamp}.#{@signed_body}")
      |> Base.encode16(case: :lower)

    conn
    |> Plug.Conn.put_req_header("content-type", "application/json")
    |> Plug.Conn.put_req_header("stripe-signature", "t=#{timestamp},v1=#{signature}")
    |> Phoenix.ConnTest.dispatch(
      FountainWeb.Endpoint,
      :post,
      "/api/stripe/webhook",
      @signed_body
    )
  end

  test "rejects an empty-key forgery when the secret is unset (nil)", %{conn: conn} do
    Application.put_env(:stripity_stripe, :webhook_secret, nil)

    conn = forge(conn, "")

    assert conn.status == 400
    assert conn.resp_body =~ "not configured"
  end

  test "rejects an empty-key forgery when the secret is set but blank", %{conn: conn} do
    Application.put_env(:stripity_stripe, :webhook_secret, "")

    conn = forge(conn, "")

    assert conn.status == 400
    assert conn.resp_body =~ "not configured"
  end
end
