defmodule Fountain.Workers.TrialEndingEmail do
  @moduledoc """
  Sends the "your trial ends in a few days" email.

  Enqueued from `customer.subscription.trial_will_end`, which Stripe fires three
  days before a trial ends and which the webhook handler received and dropped on
  the floor.

  A job rather than an inline send, for two reasons that point the same way: a
  mail failure must not make the webhook return an error and have Stripe retry
  the whole event, and a Stripe retry must not send a second email. Oban gives
  the first (retry the mail, not the webhook) and `unique` gives the second.

  The uniqueness window is a day. `Billing.handle_event/1` already claims each
  Stripe event id exactly once, so a redelivery cannot reach here twice — this
  is the belt to that braces, and cheap.
  """

  use Oban.Worker, queue: :billing, max_attempts: 5, unique: [period: 86_400, fields: [:args]]

  require Logger

  alias Fountain.{Accounts, Emails.BillingEmails}

  @spec enqueue(String.t(), DateTime.t() | nil) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(user_id, trial_ends_at) when is_binary(user_id) do
    %{
      "user_id" => user_id,
      "trial_ends_at" => trial_ends_at && DateTime.to_iso8601(trial_ends_at)
    }
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    case Accounts.get_user(user_id) do
      nil ->
        # Deleted between the webhook and the send. Nothing to do, and retrying
        # will not bring them back.
        Logger.info("trial_ending_email: user #{user_id} no longer exists")
        :ok

      user ->
        maybe_send(user, parse_ends_at(args["trial_ends_at"]))
    end
  end

  # Don't warn someone whose trial is no longer the thing that will happen. The
  # event fires three days out; if they subscribed in the meantime, telling them
  # their trial is ending is both wrong and alarming.
  defp maybe_send(%{subscription_status: "trialing"} = user, ends_at) do
    case BillingEmails.deliver_trial_ending_email(user, ends_at) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("trial_ending_email: delivery failed for #{user.id}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp maybe_send(user, _ends_at) do
    Logger.info(
      "trial_ending_email: skipping #{user.id}, status is #{user.subscription_status} not trialing"
    )

    :ok
  end

  defp parse_ends_at(nil), do: nil

  defp parse_ends_at(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
