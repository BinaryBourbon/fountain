defmodule FountainWeb.StripeWebhookController do
  @moduledoc """
  Handles `POST /api/stripe/webhook`.

  Verifies the `Stripe-Signature` header using `Stripe.Webhook.construct_event/3`,
  then dispatches to `Fountain.Billing.handle_event/1`, which claims the event
  once and applies it to the credit ledger (`Billing.apply_event/1`).

  Transient processing errors answer 500 so Stripe redelivers; permanent ones
  (unknown customer) answer 200 so Stripe stops. Both are logged and persisted
  to `stripe_webhook_failures` (#501) — written here, outside the claim
  transaction that a failed apply rolls back — and surfaced on the admin
  billing overview. A later successful delivery of the same event marks its
  failure row resolved. A 400 is returned only on signature verification
  failure; Stripe uses this to detect misconfigured webhook secrets.

  When no webhook secret is configured (nil or empty), every request is
  rejected with 400 instead of being verified against an empty HMAC key (#390).
  Signature verification is this route's only authentication, so a missing
  secret must fail closed.

  The raw request body is read from `conn.assigns[:raw_body]`, which is populated
  by `FountainWeb.CachingBodyReader` before `Plug.Parsers` consumes it.
  """

  use FountainWeb, :controller

  alias Fountain.Billing

  require Logger

  def create(conn, _params) do
    case webhook_secret() do
      {:ok, secret} ->
        verify_and_process(conn, secret)

      :error ->
        # Fail closed. `Stripe.Webhook.construct_event/3` computes a plain
        # HMAC with whatever secret it is given — an empty string verifies
        # "successfully" against a signature anyone can forge, turning this
        # unauthenticated route into write access to the credit ledger.
        Logger.error(
          "[stripe_webhook] Rejecting webhook: STRIPE_WEBHOOK_SECRET is not configured"
        )

        send_resp(conn, 400, "Webhook secret not configured")
    end
  end

  defp verify_and_process(conn, secret) do
    raw_body = conn.assigns[:raw_body] || ""
    sig_header = conn |> get_req_header("stripe-signature") |> List.first()

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
        Billing.resolve_webhook_failure(event.id)
        :ok

      {:ok, _} ->
        Billing.resolve_webhook_failure(event.id)
        :ok

      # Retrying cannot fix an event whose customer we do not recognise, so
      # acknowledge it rather than making Stripe redeliver for three days.
      # Recorded as a failure all the same: the event is gone for good, and
      # that is exactly what an operator needs to see (#501).
      {:error, :user_not_found} ->
        Logger.error("[stripe_webhook] No user for event #{event.id} (#{event.type})")
        Billing.record_webhook_failure(event, :user_not_found)
        :ok

      {:error, reason} ->
        Logger.error("[stripe_webhook] Event processing error: #{inspect(reason)}")
        Billing.record_webhook_failure(event, reason)
        :retry
    end
  rescue
    e ->
      Logger.error("[stripe_webhook] Unhandled error: #{Exception.message(e)}")
      Billing.record_webhook_failure(event, e)
      :retry
  end

  # Single source of truth: config/runtime.exs writes STRIPE_WEBHOOK_SECRET
  # to `:stripity_stripe, :webhook_secret`. (A previous version read
  # `:fountain, :stripe_webhook_secret` — a key nothing sets — and fell back
  # to `System.get_env(..., "")`, so an unset var meant verifying against "".)
  defp webhook_secret do
    case Application.get_env(:stripity_stripe, :webhook_secret) do
      secret when is_binary(secret) and secret != "" -> {:ok, secret}
      _ -> :error
    end
  end
end
