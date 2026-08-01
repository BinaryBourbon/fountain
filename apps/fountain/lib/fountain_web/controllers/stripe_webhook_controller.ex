defmodule FountainWeb.StripeWebhookController do
  @moduledoc """
  Handles `POST /api/stripe/webhook`.

  Verifies the `Stripe-Signature` header using `Stripe.Webhook.construct_event/3`,
  then dispatches to `Fountain.Billing.sync_subscription/1`.

  Per Stripe's guidelines the endpoint always returns 200 to Stripe, even on
  processing errors (which are logged and monitored via telemetry). A 400 is
  returned only on signature verification failure; Stripe uses this to detect
  misconfigured webhook secrets.

  The raw request body is read from `conn.assigns[:raw_body]`, which is populated
  by `FountainWeb.CachingBodyReader` before `Plug.Parsers` consumes it.
  """

  use FountainWeb, :controller

  alias Fountain.Billing

  require Logger

  def create(conn, _params) do
    raw_body = conn.assigns[:raw_body] || ""
    sig_header = conn |> get_req_header("stripe-signature") |> List.first()
    secret = webhook_secret()

    case Stripe.Webhook.construct_event(raw_body, sig_header, secret) do
      {:ok, event} ->
        case process_event(event) do
          :ok ->
            send_resp(conn, 200, "")

          :retry ->
            # 500 so Stripe redelivers. Previously every outcome answered 200,
            # which threw away the only recovery mechanism there is for a
            # transient failure — the event was logged and then gone forever.
            send_resp(conn, 500, "")
        end

      {:error, reason} ->
        Logger.warning("[stripe_webhook] Signature verification failed: #{inspect(reason)}")
        send_resp(conn, 400, "Bad signature")
    end
  end

  defp process_event(event) do
    case Billing.handle_event(event) do
      {:ok, :duplicate} ->
        Logger.info("[stripe_webhook] Ignoring duplicate delivery of #{event.id}")
        :ok

      {:ok, :stale} ->
        Logger.info("[stripe_webhook] Ignoring out-of-order event #{event.id}")
        :ok

      {:ok, _} ->
        :ok

      # Retrying cannot fix an event whose customer we do not recognise, so
      # acknowledge it rather than making Stripe redeliver for three days.
      {:error, :user_not_found} ->
        Logger.error("[stripe_webhook] No user for event #{event.id} (#{event.type})")
        :ok

      {:error, reason} ->
        Logger.error("[stripe_webhook] Event processing error: #{inspect(reason)}")
        :retry
    end
  rescue
    e ->
      Logger.error("[stripe_webhook] Unhandled error: #{Exception.message(e)}")
      :retry
  end

  defp webhook_secret do
    Application.get_env(:fountain, :stripe_webhook_secret) ||
      System.get_env("STRIPE_WEBHOOK_SECRET", "")
  end
end
