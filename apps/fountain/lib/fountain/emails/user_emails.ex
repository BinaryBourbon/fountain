defmodule Fountain.Emails.UserEmails do
  @moduledoc """
  Swoosh email templates for user-facing transactional emails.

  Sends:
  - Email verification (24 h token)
  - Password reset (1 h token)
  - Trial ending (3 days out, from Stripe's trial_will_end)
  - Trial expired / payment failed / subscription cancelled
    (from `Workers.LifecycleEmail`, enqueued on webhook status transitions)
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
  Warn that a trial is about to end.

  Sent three days out, from Stripe's `customer.subscription.trial_will_end`.

  The tone matters more than usual here. Until #153 trials never ended, so this
  is the first time anyone will be told their access stops — and #170 made
  account deletion a real thing that happens, so the email is explicit that
  nothing is deleted and the work is still there. Someone skim-reading "your
  trial is ending" should not conclude their agents and environments are about
  to be destroyed.
  """
  @spec deliver_trial_ending_email(User.t(), DateTime.t() | nil) ::
          {:ok, term()} | {:error, term()}
  def deliver_trial_ending_email(%User{} = user, trial_ends_at \\ nil) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"
    when_text = ends_at_phrase(trial_ends_at)

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain trial ends #{when_text}")
    |> html_body(trial_ending_html(billing_url, when_text))
    |> text_body(trial_ending_text(billing_url, when_text))
    |> Mailer.deliver()
  end

  @doc """
  Say the trial has ended, now that it has.

  The counterpart to `deliver_trial_ending_email/2`: that one warns three days
  out, this one lands when the subscription is actually cancelled. Without it
  the gate refusal *is* the notification — the user finds out from a 402 in the
  middle of whatever they were doing.

  Links to `/account/billing`, where the Upgrade button opens Stripe Checkout.
  Checkout session URLs are single-use and expire, so the email cannot carry
  one directly; the billing page mints a fresh one on click.
  """
  @spec deliver_trial_expired_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_trial_expired_email(%User{} = user) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain trial has ended")
    |> html_body(trial_expired_html(billing_url))
    |> text_body(trial_expired_text(billing_url))
    |> Mailer.deliver()
  end

  @doc """
  Dunning notice: a payment failed and the subscription is `past_due`.

  Stripe retries the charge on its own schedule, so the email says that — the
  user does not need to do anything for the retries to happen, only if they
  want the next one to succeed. Links to `/account/billing`, where the Manage
  Subscription button opens the Stripe customer portal (portal session URLs
  are short-lived, so the email cannot carry one directly).
  """
  @spec deliver_payment_failed_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_payment_failed_email(%User{} = user) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Payment failed for your Fountain subscription")
    |> html_body(payment_failed_html(billing_url))
    |> text_body(payment_failed_text(billing_url))
    |> Mailer.deliver()
  end

  @doc """
  Confirm a cancellation — theirs or dunning's.

  Three things, in order of what a just-cancelled user worries about: no
  further charges; nothing is deleted (#170 made account deletion real, so
  this email must not read like one); and coming back is a single resubscribe,
  not a restore.
  """
  @spec deliver_subscription_canceled_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_subscription_canceled_email(%User{} = user) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain subscription has been cancelled")
    |> html_body(subscription_canceled_html(billing_url))
    |> text_body(subscription_canceled_text(billing_url))
    |> Mailer.deliver()
  end

  ## Private helpers

  # "in 3 days" reads better than a timestamp, but a date is unambiguous across
  # timezones, so both.
  defp ends_at_phrase(nil), do: "soon"

  defp ends_at_phrase(%DateTime{} = at) do
    days = DateTime.diff(at, DateTime.utc_now(), :second) |> div(86_400)
    date = Calendar.strftime(at, "%-d %B")

    case days do
      d when d <= 0 -> "today (#{date})"
      1 -> "tomorrow (#{date})"
      d -> "in #{d} days (#{date})"
    end
  end

  defp trial_ending_html(billing_url, when_text) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain trial ends #{when_text}</h2>
      <p>
        When it does, your subscription will be cancelled and running sandboxes
        will stop. Add a payment method to keep going.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Add a payment method
        </a>
      </p>
      <p>
        <strong>Nothing is deleted.</strong> Your agents, environments, vaults and
        conversation history stay exactly as they are, and picking up where you
        left off is a matter of subscribing — there is no separate restore step.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{billing_url}" style="color: #3b82f6;">#{billing_url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you would rather stop here, you do not need to do anything.
      </p>
    </body>
    </html>
    """
  end

  defp trial_ending_text(billing_url, when_text) do
    """
    Your Fountain trial ends #{when_text}

    When it does, your subscription will be cancelled and running sandboxes
    will stop. Add a payment method to keep going:

    #{billing_url}

    Nothing is deleted. Your agents, environments, vaults and conversation
    history stay exactly as they are, and picking up where you left off is a
    matter of subscribing — there is no separate restore step.

    If you would rather stop here, you do not need to do anything.
    """
  end

  defp trial_expired_html(billing_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain trial has ended</h2>
      <p>
        Your trial is over, so starting new conversations is paused. Subscribe
        to pick up exactly where you left off.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Subscribe
        </a>
      </p>
      <p>
        <strong>Nothing is deleted.</strong> Your agents, environments, vaults and
        conversation history stay exactly as they are, and picking up where you
        left off is a matter of subscribing — there is no separate restore step.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{billing_url}" style="color: #3b82f6;">#{billing_url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you would rather stop here, you do not need to do anything.
      </p>
    </body>
    </html>
    """
  end

  defp trial_expired_text(billing_url) do
    """
    Your Fountain trial has ended

    Your trial is over, so starting new conversations is paused. Subscribe
    to pick up exactly where you left off:

    #{billing_url}

    Nothing is deleted. Your agents, environments, vaults and conversation
    history stay exactly as they are, and picking up where you left off is a
    matter of subscribing — there is no separate restore step.

    If you would rather stop here, you do not need to do anything.
    """
  end

  defp payment_failed_html(billing_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Payment failed for your Fountain subscription</h2>
      <p>
        Your latest payment did not go through, so starting new conversations
        is paused. We will retry the charge automatically over the next few
        days — to make the next attempt succeed, update your payment method.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Update payment method
        </a>
      </p>
      <p>
        <strong>Nothing is deleted.</strong> Your agents, environments, vaults and
        conversation history stay exactly as they are, and access comes back as
        soon as a payment succeeds.
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{billing_url}" style="color: #3b82f6;">#{billing_url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If the retries keep failing, your subscription will be cancelled.
      </p>
    </body>
    </html>
    """
  end

  defp payment_failed_text(billing_url) do
    """
    Payment failed for your Fountain subscription

    Your latest payment did not go through, so starting new conversations is
    paused. We will retry the charge automatically over the next few days —
    to make the next attempt succeed, update your payment method:

    #{billing_url}

    Nothing is deleted. Your agents, environments, vaults and conversation
    history stay exactly as they are, and access comes back as soon as a
    payment succeeds.

    If the retries keep failing, your subscription will be cancelled.
    """
  end

  defp subscription_canceled_html(billing_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your Fountain subscription has been cancelled</h2>
      <p>
        This confirms your subscription is cancelled. You will not be charged
        again, and starting new conversations is paused.
      </p>
      <p>
        <strong>Nothing is deleted.</strong> Your agents, environments, vaults and
        conversation history stay exactly as they are, and picking up where you
        left off is a matter of resubscribing — there is no separate restore step.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Resubscribe
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{billing_url}" style="color: #3b82f6;">#{billing_url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If you meant to cancel, you do not need to do anything. Thanks for
        giving Fountain a try.
      </p>
    </body>
    </html>
    """
  end

  defp subscription_canceled_text(billing_url) do
    """
    Your Fountain subscription has been cancelled

    This confirms your subscription is cancelled. You will not be charged
    again, and starting new conversations is paused.

    Nothing is deleted. Your agents, environments, vaults and conversation
    history stay exactly as they are, and picking up where you left off is a
    matter of resubscribing — there is no separate restore step:

    #{billing_url}

    If you meant to cancel, you do not need to do anything. Thanks for giving
    Fountain a try.
    """
  end

  defp from_address do
    addr = Application.get_env(:fountain, :email_from, "noreply@updates.inevitable.fyi")
    {addr, addr}
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
