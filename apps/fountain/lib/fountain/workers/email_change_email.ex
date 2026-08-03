defmodule Fountain.Workers.EmailChangeEmail do
  @moduledoc """
  The two emails of a verified email change (#448).

  - `"confirmation"` — the link to the NEW address that actually performs the
    change. The token is signed in `perform/1`, not at enqueue: nothing
    secret at rest in `oban_jobs`, and a retried job mails a fresh full-TTL
    link. Re-checks availability at send time — an address claimed between
    request and send gets no mail naming it.
  - `"notice"` — tells the OLD address the change happened. Carries both
    addresses as strings: by send time the user row already holds the new
    one.
  """

  use Oban.Worker,
    queue: :mailer,
    max_attempts: 5,
    unique: [period: 60, fields: [:worker, :args]]

  require Logger

  alias Fountain.{Accounts, Emails.UserEmails}

  @doc "Enqueue the confirmation link to `new_email` for `user`."
  def enqueue_confirmation(%Accounts.User{id: id}, new_email) when is_binary(new_email) do
    %{kind: "confirmation", user_id: id, new_email: new_email} |> new() |> Oban.insert()
  end

  @doc "Enqueue the change notice to the old address."
  def enqueue_notice(old_email, new_email)
      when is_binary(old_email) and is_binary(new_email) do
    %{kind: "notice", old_email: old_email, new_email: new_email} |> new() |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"kind" => "confirmation", "user_id" => user_id, "new_email" => new_email}
      }) do
    case Accounts.get_user(user_id) do
      nil ->
        Logger.info("email_change: user #{user_id} no longer exists")
        :ok

      user ->
        if Accounts.get_user_by_email(new_email) do
          # Claimed since the request. The requester sees nothing either way
          # (no availability oracle); they simply won't receive a link.
          :ok
        else
          token = Accounts.email_change_token(user, new_email)
          deliver(fn -> UserEmails.deliver_email_change_confirmation(new_email, token) end)
        end
    end
  end

  def perform(%Oban.Job{
        args: %{"kind" => "notice", "old_email" => old_email, "new_email" => new_email}
      }) do
    deliver(fn -> UserEmails.deliver_email_changed_notice(old_email, new_email) end)
  end

  defp deliver(fun) do
    case fun.() do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("email_change: delivery failed: #{inspect(reason)}")
        {:error, reason}
    end
  end
end
