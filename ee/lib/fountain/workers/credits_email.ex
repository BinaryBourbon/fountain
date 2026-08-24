defmodule Fountain.Workers.CreditsEmail do
  @moduledoc """
  Runway warnings for the prepaid balance (ADR 0030 decision 6).

  Two kinds: `"credits_low"` when the balance drops under the runway line
  (20 % of the period's tier grant, or $2, whichever is larger) and
  `"credits_exhausted"` when it reaches zero. Enqueued by the pricer after a
  burn; unique per user and kind for thirty days, so a tenant hovering at
  the line gets one email a period, not one a burn.

  Only sends while the state still holds: a top-up between the enqueue and
  the send makes the email a lie, and it is dropped.
  """

  use Oban.Worker,
    queue: :billing,
    max_attempts: 5,
    unique: [period: 30 * 86_400, fields: [:args]]

  require Logger

  alias Fountain.{Accounts, Credits, Emails.BillingEmails}

  @emails ~w(credits_low credits_exhausted)

  def emails, do: @emails

  @spec enqueue(String.t(), String.t()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(user_id, email) when is_binary(user_id) and email in @emails do
    %{"user_id" => user_id, "email" => email} |> new() |> Oban.insert()
  end

  @doc """
  Look at one tenant's balance after a burn and enqueue whichever warning
  applies. Nothing when credits are not active, or the tenant is comped.
  """
  @spec notify_after_burn(String.t()) :: :ok
  def notify_after_burn(user_id) when is_binary(user_id) do
    with true <- Credits.active?(),
         %{subscription_status: status} = user when status != "comped" <-
           Accounts.get_user(user_id) do
      balance = Credits.balance(user)

      cond do
        balance <= 0 -> enqueue(user.id, "credits_exhausted")
        balance <= runway_line(user) -> enqueue(user.id, "credits_low")
        true -> :ok
      end
    end

    :ok
  end

  @doc "Cents under which a balance is 'low': 20 % of the tier grant, or $2."
  @spec runway_line(Accounts.User.t()) :: pos_integer()
  def runway_line(user) do
    grant = Fountain.Plans.included_turn_hours(user) * Credits.price_card().turn_hour
    max(div(grant, 5), 200)
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "email" => email}}) when email in @emails do
    case Accounts.get_user(user_id) do
      nil ->
        :ok

      user ->
        balance = Credits.balance(user)

        cond do
          user.subscription_status == "comped" ->
            :ok

          email == "credits_exhausted" and balance <= 0 ->
            BillingEmails.deliver_credits_exhausted_email(user, balance) |> log(user, email)

          email == "credits_low" and balance > 0 and balance <= runway_line(user) ->
            BillingEmails.deliver_credits_low_email(user, balance) |> log(user, email)

          true ->
            :ok
        end
    end
  end

  defp log({:ok, _}, user, email) do
    Logger.info("credits_email: sent #{email} to #{user.id}")
    :ok
  end

  defp log({:error, reason}, user, email) do
    Logger.error("credits_email: #{email} to #{user.id} failed: #{inspect(reason)}")
    {:error, reason}
  end
end
