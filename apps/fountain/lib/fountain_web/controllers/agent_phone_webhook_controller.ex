defmodule FountainWeb.AgentPhoneWebhookController do
  @moduledoc """
  AgentPhone's master webhook: every inbound message on the account's
  numbers lands here (flag `team_comms`). Like the Stripe webhook, no bearer
  token — the request is authenticated by its HMAC signature:
  `X-Webhook-Signature: sha256=<hex>` over `"<timestamp>.<raw_body>"` with
  the secret AgentPhone issued when the webhook was registered
  (`AGENTPHONE_WEBHOOK_SECRET`), and `X-Webhook-Timestamp` within five
  minutes. The raw body comes from `conn.assigns[:raw_body]`
  (`FountainWeb.CachingBodyReader`).

  A verified delivery is handed to `Fountain.Team.Comms.Inbound`; the answer
  is always `200` so AgentPhone does not retry a delivery we deliberately
  ignored — the body says what happened. Unverifiable → `401`; no secret
  configured → `503` (nothing is processed unsigned).
  """
  use FountainWeb, :controller

  alias Fountain.Team.Comms.Inbound

  @max_skew_seconds 300

  def create(conn, _params) do
    case secret() do
      nil ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "agentphone_webhook_not_configured"})

      secret ->
        raw = conn.assigns[:raw_body] || ""
        sig = first_header(conn, "x-webhook-signature")
        ts = first_header(conn, "x-webhook-timestamp")

        if verified?(raw, sig, ts, secret) do
          delivery_id = first_header(conn, "x-webhook-id")

          result =
            case conn.body_params do
              # A voice event wants a spoken reply; a teammate's number does
              # not take calls (voiceMode "webhook", see Comms), so say so
              # and hang up rather than leaving the caller in silence.
              %{"event" => "agent.message", "channel" => "voice"} ->
                %{text: "This number only receives text messages. Goodbye.", hangup: true}

              payload ->
                case Inbound.handle(payload, delivery_id) do
                  {:ok, conv_id} -> %{status: "prompted", conversation_id: conv_id}
                  {:ignored, reason} -> %{status: "ignored", reason: describe(reason)}
                end
            end

          json(conn, result)
        else
          conn |> put_status(:unauthorized) |> json(%{error: "invalid_signature"})
        end
    end
  end

  @doc false
  def verified?(raw, "sha256=" <> hex, ts, secret) when is_binary(hex) and is_binary(ts) do
    with {unix, ""} <- Integer.parse(ts),
         true <- abs(System.os_time(:second) - unix) <= @max_skew_seconds do
      expected =
        :crypto.mac(:hmac, :sha256, secret, ts <> "." <> raw) |> Base.encode16(case: :lower)

      Plug.Crypto.secure_compare(expected, String.downcase(hex))
    else
      _ -> false
    end
  end

  def verified?(_raw, _sig, _ts, _secret), do: false

  defp first_header(conn, name) do
    case get_req_header(conn, name) do
      [v | _] -> v
      [] -> nil
    end
  end

  defp describe({:send_failed, reason}), do: "send_failed: #{inspect(reason)}"
  defp describe(reason), do: to_string(reason)

  defp secret do
    case Application.get_env(:fountain, :agentphone_webhook_secret) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end
end
