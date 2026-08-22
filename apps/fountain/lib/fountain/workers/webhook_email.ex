defmodule Fountain.Workers.WebhookEmail do
  @moduledoc """
  "Your webhook endpoint was switched off" (#700).

  Its own worker rather than a kind on `Workers.AccountEmail`, because the
  guard is different: that worker re-checks account *state* at send time, and
  the question here is whether this particular endpoint is still disabled. An
  owner who re-enabled it in the seconds before the queue drained should not
  then be told it is off.

  Unique per endpoint for an hour, so a burst of events all crossing the
  threshold together sends one mail rather than five.
  """

  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [keys: [:endpoint_id], period: 3600]

  alias Fountain.{Accounts, Emails.UserEmails, Webhooks}

  @doc "Enqueue the switched-off notice for one endpoint."
  def enqueue_disabled(endpoint_id) when is_binary(endpoint_id) do
    %{endpoint_id: endpoint_id} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"endpoint_id" => id}}) do
    with %{status: "disabled"} = endpoint <- Webhooks._unsafe_get_endpoint(id),
         %{email_verified_at: verified_at} = user when not is_nil(verified_at) <-
           Accounts.get_user(endpoint.user_id) do
      host = URI.parse(endpoint.url).host || endpoint.url
      reason = endpoint.disabled_reason || "repeated delivery failures"

      case UserEmails.deliver_webhook_disabled_email(user, host, reason) do
        {:ok, _} -> :ok
        # Retried by Oban; the endpoint stays disabled either way.
        {:error, error} -> {:error, error}
      end
    else
      _ -> :ok
    end
  end
end
