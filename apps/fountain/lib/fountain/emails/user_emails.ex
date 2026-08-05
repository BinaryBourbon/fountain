defmodule Fountain.Emails.UserEmails do
  @moduledoc """
  Swoosh templates for account email — the mail any instance needs.

  Sends:
  - Email verification (24 h token, from `Workers.VerificationEmail`)
  - Password reset (1 h token)
  - Account suspended / unsuspended / deleted (from `Workers.AccountEmail`)
  - Email-change confirmation + notice (from `Workers.EmailChangeEmail`)

  Billing-adjacent and growth mail (welcome, trial, payment lifecycle) lives
  in `Fountain.Emails.BillingEmails` under ee/ (#475) — it borrows
  `from_address/0` and `support_phrase/0` from here so the whole mail
  surface keeps one sender and one support-contact policy.
  """

  import Swoosh.Email

  alias Fountain.Accounts.User
  alias Fountain.Mailer

  @doc """
  Build and deliver a verification email.

  `token` is a `Phoenix.Token`-signed string encoding the user id.
  The recipient must click the link within 24 hours.
  """
  @spec deliver_verification_email(User.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_verification_email(%User{} = user, token) do
    base_url = Fountain.PublicUrl.base()
    verify_url = "#{base_url}/users/confirm/#{token}"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Verify your Fountain account")
    |> html_body(verification_html(verify_url))
    |> text_body(verification_text(verify_url))
    |> Mailer.deliver()
  end

  @doc """
  Build and deliver a password-reset email.

  `token` is a `Phoenix.Token`-signed string. The link expires in 1 hour.
  """
  @spec deliver_password_reset_email(User.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_password_reset_email(%User{} = user, token) do
    base_url = Fountain.PublicUrl.base()
    reset_url = "#{base_url}/auth/reset/#{token}"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Reset your Fountain password")
    |> html_body(reset_html(reset_url))
    |> text_body(reset_text(reset_url))
    |> Mailer.deliver()
  end

  @doc """
  Tell a user their account was suspended (#450).

  Before this the only signal was a generic "account currently unavailable"
  at the next login attempt — no explanation, no route to appeal. Deliberately
  does not say *why*: the reason lives in the admin audit trail, and an email
  template can't know it. Points at support instead.
  """
  @spec deliver_account_suspended_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_account_suspended_email(%User{} = user) do
    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain account has been suspended")
    |> html_body(account_suspended_html())
    |> text_body(account_suspended_text())
    |> Mailer.deliver()
  end

  @doc "The counterpart: the suspension was lifted; sign in again (#450)."
  @spec deliver_account_unsuspended_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_account_unsuspended_email(%User{} = user) do
    login_url = "#{Fountain.PublicUrl.base()}/auth/login"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain account is available again")
    |> html_body(account_unsuspended_html(login_url))
    |> text_body(account_unsuspended_text(login_url))
    |> Mailer.deliver()
  end

  @doc """
  Confirm an account deletion (#450).

  Takes a raw address, not a `User` — by send time the row is gone. Honest
  about the two things that survive: Stripe keeps the invoices (financial
  records), and backups age out on their own schedule.
  """
  @spec deliver_account_deleted_email(String.t()) :: {:ok, term()} | {:error, term()}
  def deliver_account_deleted_email(email) when is_binary(email) do
    new()
    |> from(from_address())
    |> to({email, email})
    |> subject("Your Fountain account has been deleted")
    |> html_body(account_deleted_html())
    |> text_body(account_deleted_text())
    |> Mailer.deliver()
  end

  @doc """
  The email-change confirmation, sent to the NEW address (#448).

  Clicking the link is what performs the change; until then nothing happens,
  and the copy says so — the recipient may never have heard of Fountain.
  """
  @spec deliver_email_change_confirmation(String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_email_change_confirmation(new_email, token) when is_binary(new_email) do
    confirm_url = "#{Fountain.PublicUrl.base()}/account/email/confirm/#{token}"

    new()
    |> from(from_address())
    |> to({new_email, new_email})
    |> subject("Confirm your new Fountain email address")
    |> html_body(email_change_html(confirm_url))
    |> text_body(email_change_text(confirm_url))
    |> Mailer.deliver()
  end

  @doc """
  Tell the OLD address its account's email changed (#448). This is the
  account-takeover tripwire: the old address can no longer sign in, so the
  copy points at support rather than at a login form.
  """
  @spec deliver_email_changed_notice(String.t(), String.t()) ::
          {:ok, term()} | {:error, term()}
  def deliver_email_changed_notice(old_email, new_email) do
    new()
    |> from(from_address())
    |> to({old_email, old_email})
    |> subject("Your Fountain email address was changed")
    |> html_body(email_changed_notice_html(new_email))
    |> text_body(email_changed_notice_text(new_email))
    |> Mailer.deliver()
  end

  ## Private helpers

  defp email_change_html(url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Confirm your new Fountain email address</h2>
      <p>
        A Fountain account asked to change its email address to this one.
        Click the button below to confirm — the change only happens when you
        do. The link expires in 24 hours.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Confirm new address
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{url}" style="color: #3b82f6;">#{url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you didn't request this, you can safely ignore this email — nothing
        changes unless the link is clicked.
      </p>
    </body>
    </html>
    """
  end

  defp email_change_text(url) do
    """
    Confirm your new Fountain email address

    A Fountain account asked to change its email address to this one. Open
    the link below to confirm — the change only happens when you do. The link
    expires in 24 hours.

    #{url}

    If you didn't request this, you can safely ignore this email — nothing
    changes unless the link is clicked.
    """
  end

  defp email_changed_notice_html(new_email) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain email address was changed</h2>
      <p>
        The email address on your Fountain account was changed to
        <strong>#{new_email}</strong>. This address can no longer be used to
        sign in.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you made this change, no action is needed. If you did not,
        #{support_phrase()} immediately — do not wait.
      </p>
    </body>
    </html>
    """
  end

  defp email_changed_notice_text(new_email) do
    """
    Your Fountain email address was changed

    The email address on your Fountain account was changed to #{new_email}.
    This address can no longer be used to sign in.

    If you made this change, no action is needed. If you did not,
    #{support_phrase()} immediately — do not wait.
    """
  end

  # Public (not defp): Fountain.Emails.BillingEmails (ee/) shares the sender
  # and support-contact policy rather than duplicating it.
  @doc false
  def from_address do
    addr = Application.get_env(:fountain, :email_from, "noreply@updates.inevitable.fyi")
    {addr, addr}
  end

  # "contact us at x@y" when SUPPORT_EMAIL is configured; a from-address that
  # starts with noreply@ makes "reply to this email" a lie, so without it the
  # copy stays vague rather than pointing somewhere replies go to die.
  # Public for the same reason as from_address/0.
  @doc false
  def support_phrase do
    case Application.get_env(:fountain, :support_email) do
      addr when is_binary(addr) and addr != "" -> "contact us at #{addr}"
      _ -> "contact support"
    end
  end

  defp account_suspended_html do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain account has been suspended</h2>
      <p>
        Your account has been suspended: existing sessions are signed out, API
        keys stop working, and running conversations have been stopped.
      </p>
      <p>
        <strong>Nothing is deleted.</strong> Your agents, environments, vaults and
        conversation history stay exactly as they are, and your subscription is
        not changed by a suspension.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you believe this is an error, #{support_phrase()}.
      </p>
    </body>
    </html>
    """
  end

  defp account_suspended_text do
    """
    Your Fountain account has been suspended

    Your account has been suspended: existing sessions are signed out, API
    keys stop working, and running conversations have been stopped.

    Nothing is deleted. Your agents, environments, vaults and conversation
    history stay exactly as they are, and your subscription is not changed by
    a suspension.

    If you believe this is an error, #{support_phrase()}.
    """
  end

  defp account_unsuspended_html(login_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain account is available again</h2>
      <p>
        The suspension on your account has been lifted. Sign in to pick up
        where you left off — everything is as you left it.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{login_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Sign in
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{login_url}" style="color: #3b82f6;">#{login_url}</a>
      </p>
    </body>
    </html>
    """
  end

  defp account_unsuspended_text(login_url) do
    """
    Your Fountain account is available again

    The suspension on your account has been lifted. Sign in to pick up where
    you left off — everything is as you left it:

    #{login_url}
    """
  end

  defp account_deleted_html do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain account has been deleted</h2>
      <p>
        This confirms your Fountain account and its data — agents,
        environments, vaults, conversations and stored secrets — have been
        permanently deleted. Any subscription was cancelled first; you will
        not be charged again.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Past invoices remain available from Stripe, as financial records.
        Database backups that predate the deletion age out on their own
        retention schedule.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you did not request this, #{support_phrase()} immediately.
      </p>
    </body>
    </html>
    """
  end

  defp account_deleted_text do
    """
    Your Fountain account has been deleted

    This confirms your Fountain account and its data — agents, environments,
    vaults, conversations and stored secrets — have been permanently deleted.
    Any subscription was cancelled first; you will not be charged again.

    Past invoices remain available from Stripe, as financial records. Database
    backups that predate the deletion age out on their own retention schedule.

    If you did not request this, #{support_phrase()} immediately.
    """
  end

  defp verification_html(url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Verify your Fountain account</h2>
      <p>Click the button below to verify your email address. This link expires in 24 hours.</p>
      <p style="margin: 32px 0;">
        <a href="#{url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Verify email address
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{url}" style="color: #3b82f6;">#{url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you didn't sign up for Fountain, you can safely ignore this email.
      </p>
    </body>
    </html>
    """
  end

  defp verification_text(url) do
    """
    Verify your Fountain account

    Click the link below to verify your email address.
    This link expires in 24 hours.

    #{url}

    If you didn't sign up for Fountain, you can safely ignore this email.
    """
  end

  defp reset_html(url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Reset your Fountain password</h2>
      <p>Someone requested a password reset for your account. Click the button below to set a new password. This link expires in 1 hour.</p>
      <p style="margin: 32px 0;">
        <a href="#{url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Reset password
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{url}" style="color: #3b82f6;">#{url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you didn't request a password reset, you can safely ignore this email.
        Your password has not been changed.
      </p>
    </body>
    </html>
    """
  end

  defp reset_text(url) do
    """
    Reset your Fountain password

    Someone requested a password reset for your account.
    Click the link below to set a new password.
    This link expires in 1 hour.

    #{url}

    If you didn't request a password reset, you can safely ignore this email.
    Your password has not been changed.
    """
  end
end
