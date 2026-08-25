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

  # The opening grant (ADR 0031), in the welcome: what they start with and
  # how long it lasts. Nothing when billing is off.
  defp welcome_trial_phrase(%User{}) do
    if Fountain.Billing.enabled?() do
      cfg = Application.get_env(:fountain, :credits, [])
      cents = Keyword.get(cfg, :opening_cents, 500)
      days = Keyword.get(cfg, :opening_days, 14)

      "Your account starts with #{Fountain.Credits.format_cents(cents)} of credit, good for " <>
        "#{days} days — no card needed until then."
    end
  end

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

  @doc """
  The prepaid balance is under the runway line (ADR 0030 decision 6).
  """
  @spec deliver_credits_low_email(User.t(), integer()) :: {:ok, term()} | {:error, term()}
  def deliver_credits_low_email(%User{} = user, balance_cents) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"
    balance = Fountain.Credits.format_cents(balance_cents)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain credit is running low")
    |> html_body(credits_html("Your credit is running low", balance, billing_url, false))
    |> text_body(credits_text("Your credit is running low", balance, billing_url, false))
    |> Mailer.deliver()
  end

  @doc """
  The prepaid balance is at or below zero. Whether anything is refused
  depends on `Fountain.Credits.enforcing?/0`; the email says so either way.
  """
  @spec deliver_credits_exhausted_email(User.t(), integer()) :: {:ok, term()} | {:error, term()}
  def deliver_credits_exhausted_email(%User{} = user, balance_cents) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"
    balance = Fountain.Credits.format_cents(balance_cents)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your Fountain credit has run out")
    |> html_body(credits_html("Your credit has run out", balance, billing_url, true))
    |> text_body(credits_text("Your credit has run out", balance, billing_url, true))
    |> Mailer.deliver()
  end

  defp credits_consequence(true) do
    if Fountain.Credits.enforcing?(),
      do:
        "New conversations and new turns are paused until the balance is positive again. Anything already running finishes.",
      else: "Nothing is paused yet. Your balance will keep going down until you top up."
  end

  defp credits_consequence(false),
    do:
      "Your plan adds credit at the start of every billing period. Top up now if you need more before then."

  defp credits_html(title, balance, billing_url, exhausted?) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>#{title}</h2>
      <p>Your prepaid balance is <strong>#{balance}</strong>.</p>
      <p>#{credits_consequence(exhausted?)}</p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Buy credits
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        Credits you buy never expire and are spent after the credit your plan includes.
      </p>
    </body>
    </html>
    """
  end

  defp credits_text(title, balance, billing_url, exhausted?) do
    """
    #{title}

    Your prepaid balance is #{balance}.

    #{credits_consequence(exhausted?)}

    Buy credits: #{billing_url}

    Credits you buy never expire and are spent after the credit your plan includes.
    """
  end

  @doc """
  Rent for a teammate's number and inbox could not be paid; `days_left` of
  the grace remain before the contact is released (ADR 0030 decision 4).
  """
  @spec deliver_rent_due_email(User.t(), Fountain.Team.Contact.t(), non_neg_integer()) ::
          {:ok, term()} | {:error, term()}
  def deliver_rent_due_email(%User{} = user, contact, days_left) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"

    what =
      [contact.phone_number, contact.email_address]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" and ")

    rent = Fountain.Credits.format_cents(Fountain.Credits.Rent.month_cents())

    when_ =
      case days_left do
        0 -> "today"
        1 -> "tomorrow"
        n -> "in #{n} days"
      end

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your teammate's number will be released #{when_}")
    |> html_body(rent_due_html(what, rent, when_, billing_url))
    |> text_body(rent_due_text(what, rent, when_, billing_url))
    |> Mailer.deliver()
  end

  defp rent_due_html(what, rent, when_, billing_url) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Your teammate's number will be released #{when_}</h2>
      <p>
        The monthly rent of <strong>#{rent}</strong> for <strong>#{what}</strong> could
        not be taken from your credit balance. If the balance is still short #{when_},
        the number and inbox are released, and a released number cannot be recovered.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{billing_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Buy credits
        </a>
      </p>
      <p style="color: #71717a; font-size: 13px;">
        As soon as the balance covers the rent, it is paid and the number stays.
      </p>
    </body>
    </html>
    """
  end

  defp rent_due_text(what, rent, when_, billing_url) do
    """
    Your teammate's number will be released #{when_}

    The monthly rent of #{rent} for #{what} could not be taken from your
    credit balance. If the balance is still short #{when_}, the number and
    inbox are released, and a released number cannot be recovered.

    Buy credits: #{billing_url}

    As soon as the balance covers the rent, it is paid and the number stays.
    """
  end
end
