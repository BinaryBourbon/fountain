defmodule Fountain.Emails.UserEmails do
  @moduledoc """
  Swoosh email templates for user-facing transactional emails.

  Sends:
  - Email verification (24 h token, from `Workers.VerificationEmail`)
  - Welcome (once, on the verification transition, from `Workers.WelcomeEmail`)
  - Password reset (1 h token)
  - Trial ending (3 days out, from Stripe's trial_will_end)
  - Trial expired / payment failed / payment action required / payment
    recovered / subscription cancelled (from `Workers.LifecycleEmail`,
    enqueued on webhook status transitions and `invoice.*` events)
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
  Welcome a just-verified user (#449).

  The first email that isn't a chore: everything before it is a verification
  link and everything after it is billing. Says what to do next (the
  onboarding wizard) and, for trialing accounts, when the trial ends — the
  same phrasing `deliver_trial_ending_email/2` will use later, so the two
  emails agree on the date.
  """
  @spec deliver_welcome_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_welcome_email(%User{} = user) do
    base_url = Fountain.PublicUrl.base()

    start_url =
      if user.onboarding_completed_at do
        base_url
      else
        "#{base_url}/onboarding/step_1"
      end

    trial_text = welcome_trial_phrase(user)

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Welcome to Fountain")
    |> html_body(welcome_html(start_url, trial_text))
    |> text_body(welcome_text(start_url, trial_text))
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
  The bank wants confirmation before the charge goes through (#447).

  Driven by Stripe's `invoice.payment_action_required` — an SCA/3DS challenge
  on a renewal. This is the one dunning-adjacent email where the user can
  still prevent the failure, so it leads with the action, not the problem.
  """
  @spec deliver_payment_action_required_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_payment_action_required_email(%User{} = user) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Action needed: confirm your Fountain payment")
    |> html_body(payment_action_required_html(billing_url))
    |> text_body(payment_action_required_text(billing_url))
    |> Mailer.deliver()
  end

  @doc """
  Dunning recovered (#447): a past_due account's payment went through.

  The counterpart to `deliver_payment_failed_email/1`. Without it the account
  silently unlocks and the failure notice stays the last thing we ever said.
  """
  @spec deliver_payment_recovered_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_payment_recovered_email(%User{} = user) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"

    new()
    |> from(from_address())
    |> to({user.email, user.email})
    |> subject("Payment received — your Fountain subscription is active")
    |> html_body(payment_recovered_html(billing_url))
    |> text_body(payment_recovered_text(billing_url))
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

  defp welcome_trial_phrase(%User{
         subscription_status: "trialing",
         trial_ends_at: %DateTime{} = at
       }),
       do: "Your free trial ends #{ends_at_phrase(at)} — no card needed until then."

  defp welcome_trial_phrase(_user), do: nil

  defp welcome_html(start_url, trial_text) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Welcome to Fountain</h2>
      <p>
        Your account is verified and ready. Set up an agent, give it an
        environment, and start a conversation — it runs in an isolated sandbox
        and streams back live.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{start_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Get started
        </a>
      </p>
      #{if trial_text, do: "<p>#{trial_text}</p>", else: ""}
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{start_url}" style="color: #3b82f6;">#{start_url}</a>
      </p>
    </body>
    </html>
    """
  end

  defp welcome_text(start_url, trial_text) do
    """
    Welcome to Fountain

    Your account is verified and ready. Set up an agent, give it an
    environment, and start a conversation — it runs in an isolated sandbox
    and streams back live:

    #{start_url}
    #{if trial_text, do: "\n#{trial_text}\n", else: ""}
    """
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

  defp payment_action_required_html(billing_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Confirm your Fountain payment</h2>
      <p>
        Your bank is asking for an extra confirmation before it will approve
        your latest Fountain payment. Until then the charge stays pending.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Confirm payment
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{billing_url}" style="color: #3b82f6;">#{billing_url}</a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        If the payment is not confirmed, it will be treated as failed and
        retried — you'll hear from us again if that happens.
      </p>
    </body>
    </html>
    """
  end

  defp payment_action_required_text(billing_url) do
    """
    Confirm your Fountain payment

    Your bank is asking for an extra confirmation before it will approve your
    latest Fountain payment. Until then the charge stays pending. Confirm it
    here:

    #{billing_url}

    If the payment is not confirmed, it will be treated as failed and retried
    — you'll hear from us again if that happens.
    """
  end

  defp payment_recovered_html(billing_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Payment received — you're all set</h2>
      <p>
        Your payment went through and your Fountain subscription is active
        again. Starting new conversations works as normal, and nothing was
        deleted while the payment was outstanding.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          View billing
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{billing_url}" style="color: #3b82f6;">#{billing_url}</a>
      </p>
    </body>
    </html>
    """
  end

  defp payment_recovered_text(billing_url) do
    """
    Payment received — you're all set

    Your payment went through and your Fountain subscription is active again.
    Starting new conversations works as normal, and nothing was deleted while
    the payment was outstanding.

    #{billing_url}
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

  defp from_address do
    addr = Application.get_env(:fountain, :email_from, "noreply@updates.inevitable.fyi")
    {addr, addr}
  end

  # "contact us at x@y" when SUPPORT_EMAIL is configured; a from-address that
  # starts with noreply@ makes "reply to this email" a lie, so without it the
  # copy stays vague rather than pointing somewhere replies go to die.
  defp support_phrase do
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
