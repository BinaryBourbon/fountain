defmodule Fountain.Workers.StripeCustomerSync do
  @moduledoc """
  Ensures a user has a Stripe Customer.

  This ran as a bare `Task.async` with no `await`, from the email-verification
  request. The task was *linked* to the request process, so it could be killed
  when that process finished, and a Stripe API error had no retry, no log and no
  repair path — it just silently produced a user with a nil `stripe_customer_id`.

  That mattered more than it looks: 153 of 190 production accounts have no
  customer id, and until #212 those accounts hit a Checkout flow that charged
  the card and never activated the account.

  As a job it retries with backoff and survives a restart. It is also
  idempotent — `ensure_stripe_customer/1` returns the existing customer
  untouched — so a duplicate run cannot mint a second Customer.
  """

  use Oban.Worker, queue: :billing, max_attempts: 5, unique: [period: 300, fields: [:args]]

  require Logger

  alias Fountain.{Accounts, Billing}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id}}) do
    case Accounts.get_user(user_id) do
      nil ->
        # The account was deleted between enqueue and execution. Nothing to do,
        # and retrying will not bring it back.
        Logger.info("stripe_customer_sync: user #{user_id} no longer exists")
        :ok

      user ->
        case ensure_customer_and_trial(user) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            # Returning an error tuple lets Oban retry with backoff rather than
            # losing this the way the old fire-and-forget Task did.
            Logger.warning("stripe_customer_sync: failed for #{user_id}: #{inspect(reason)}")

            {:error, reason}
        end
    end
  end

  @doc "Enqueue customer creation for `user`."
  def enqueue(%Accounts.User{id: id}), do: enqueue(id)

  def enqueue(user_id) when is_binary(user_id) do
    %{user_id: user_id}
    |> new()
    |> Oban.insert()
  end

  # The customer and the trial subscription, in that order. Split because
  # Billing.create_stripe_customer/1 is also on the Checkout path, where opening
  # a trial moments before a paid subscription would be wrong.
  #
  # A user who already has a subscription is left alone: this job is unique per
  # user for 5 minutes but not forever, and minting a second subscription for
  # someone who already converted would bill them twice.
  defp ensure_customer_and_trial(user) do
    with {:ok, user} <- Billing.ensure_stripe_customer(user) do
      if user.subscription_status == "trialing" and is_nil(user.trial_ends_at) do
        Billing.start_trial_subscription(user)
      else
        {:ok, user}
      end
    end
  end
end
