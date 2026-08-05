defmodule Fountain.Workers.LifecycleEmail do
  @moduledoc """
  Sends the post-trial and payment-failure lifecycle emails (#283):

  - `"trial_expired"` — the trial ended without a card and the subscription was
    cancelled. Says so, links to billing to subscribe.
  - `"payment_failed"` — the subscription went `past_due`. Dunning notice with
    a link to update the payment method.
  - `"subscription_canceled"` — the subscription ended (their choice or
    dunning exhaustion). Confirmation, the data-retention story, the way back.
  - `"payment_action_required"` (#447) — the bank wants SCA/3DS confirmation
    before the charge goes through. Without it the user's first sign is the
    dunning email for a failure they could have prevented in one click.
  - `"payment_recovered"` (#447) — a past_due account paid up. The counterpart
    to `"payment_failed"`; without it the account silently unlocks and the
    dunning email stays the last word.

  Enqueued from `Billing.sync_subscription/1` on the status *transition*, never
  on the status itself — Stripe fires several `customer.subscription.updated`
  events per dunning cycle, all carrying `past_due`, and only the first one is
  news.

  A job rather than an inline send, same as `Workers.TrialEndingEmail` and for
  the same two reasons: a mail failure must not make the webhook return an
  error and have Stripe retry the whole event, and a Stripe retry must not send
  a second email. Oban gives the first (retry the mail, not the webhook) and
  `unique` gives the second. `Billing.handle_event/1` already claims each
  Stripe event id exactly once, so a redelivery cannot reach here twice — the
  uniqueness window is the belt to that braces.
  """

  use Oban.Worker, queue: :billing, max_attempts: 5, unique: [period: 86_400, fields: [:args]]

  require Logger

  alias Fountain.{Accounts, Emails.UserEmails}

  @emails ~w(trial_expired payment_failed subscription_canceled payment_action_required payment_recovered)

  @doc "The email kinds this worker knows how to send."
  def emails, do: @emails

  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(user_id, email) when is_binary(user_id) and email in @emails do
    %{"user_id" => user_id, "email" => email}
    |> new()
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "email" => email}})
      when email in @emails do
    case Accounts.get_user(user_id) do
      nil ->
        # Deleted between the webhook and the send. Nothing to do, and retrying
        # will not bring them back.
        Logger.info("lifecycle_email: user #{user_id} no longer exists")
        :ok

      user ->
        maybe_send(user, email)
    end
  end

  # Only send while the state the email describes still holds. The queue can
  # lag the account: someone who subscribed after their trial expired, or fixed
  # their card an hour after it bounced, must not then be told the opposite.
  defp maybe_send(%{subscription_status: "canceled"} = user, "trial_expired"),
    do: deliver(user, "trial_expired", &UserEmails.deliver_trial_expired_email/1)

  defp maybe_send(%{subscription_status: "past_due"} = user, "payment_failed"),
    do: deliver(user, "payment_failed", &UserEmails.deliver_payment_failed_email/1)

  defp maybe_send(%{subscription_status: "canceled"} = user, "subscription_canceled"),
    do: deliver(user, "subscription_canceled", &UserEmails.deliver_subscription_canceled_email/1)

  # An open invoice can want SCA while the account is in any live state — a
  # renewal on an active account, a retry on a past_due one. Only a canceled
  # account is past the point where confirming would help.
  defp maybe_send(%{subscription_status: s} = user, "payment_action_required")
       when s in ["trialing", "active", "past_due"],
       do:
         deliver(
           user,
           "payment_action_required",
           &UserEmails.deliver_payment_action_required_email/1
         )

  defp maybe_send(%{subscription_status: "active"} = user, "payment_recovered"),
    do: deliver(user, "payment_recovered", &UserEmails.deliver_payment_recovered_email/1)

  defp maybe_send(user, email) do
    Logger.info(
      "lifecycle_email: skipping #{email} for #{user.id}, status is now #{user.subscription_status}"
    )

    :ok
  end

  defp deliver(user, email, deliver_fun) do
    case deliver_fun.(user) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "lifecycle_email: #{email} delivery failed for #{user.id}: #{inspect(reason)}"
        )

        {:error, reason}
    end
  end
end
