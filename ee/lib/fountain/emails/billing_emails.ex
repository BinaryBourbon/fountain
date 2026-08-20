defmodule Fountain.Emails.BillingEmails do
  @moduledoc """
  Swoosh templates for billing-adjacent and growth email (EE).

  Split out of `Fountain.Emails.UserEmails` in #475: account mail
  (verification, password reset, suspension, deletion, email change) is core;
  everything here only makes sense on an instance with billing enabled.

  Sends:
  - Welcome (once, on the verification transition, from `Workers.WelcomeEmail`)
  - Trial ending (3 days out, from Stripe's trial_will_end)
  - Trial expired / payment failed / payment action required / payment
    recovered / subscription cancelled (from `Workers.LifecycleEmail`,
    enqueued on webhook status transitions and `invoice.*` events)

  Shares `UserEmails.from_address/0` and `UserEmails.support_phrase/0` so the
  whole mail surface keeps one sender and one support-contact policy.
  """

  import Swoosh.Email

  alias Fountain.Accounts.User
  alias Fountain.Emails.UserEmails
  alias Fountain.Mailer

  @doc """
  Welcome a just-verified user (#449).

  The first email that isn't a chore: everything before it is a verification
  link and everything after it is billing. Says what to do next (the console,
  which lists what is still missing) and, for trialing accounts, when the
  trial ends — the same phrasing `deliver_trial_ending_email/2` will use
  later, so the two emails agree on the date.
  """
  @spec deliver_welcome_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_welcome_email(%User{} = user) do
    base_url = Fountain.PublicUrl.base()

    # The console's dashboard, whatever the account has set up: it is the
    # thing that says what is still missing (#867).
    start_url = "#{base_url}/dashboard"

    trial_text = welcome_trial_phrase(user)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Welcome to Fountain")
    |> html_body(welcome_html(start_url, trial_text))
    |> text_body(welcome_text(start_url, trial_text))
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
    |> from(UserEmails.from_address())
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
    |> from(UserEmails.from_address())
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
    |> from(UserEmails.from_address())
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
    |> from(UserEmails.from_address())
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
    |> from(UserEmails.from_address())
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
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain subscription has been cancelled")
    |> html_body(subscription_canceled_html(billing_url))
    |> text_body(subscription_canceled_text(billing_url))
    |> Mailer.deliver()
  end

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
end
