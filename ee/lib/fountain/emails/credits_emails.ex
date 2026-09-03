defmodule Fountain.Emails.CreditsEmails do
  @moduledoc """
  Swoosh templates for the credit emails and the welcome (EE).

  Split out of `Fountain.Emails.UserEmails` in #475: account mail
  (verification, password reset, suspension, deletion, email change) is core;
  everything here only makes sense on an instance with billing enabled.

  Sends:
  - Welcome (once, on the verification transition, from `Workers.WelcomeEmail`)
  - Credits low and credits exhausted (from `Workers.CreditsEmail`, after a
    burn crosses the threshold or zero)
  - Rent due (from `Workers.CreditsEmail`, on days 0, 3 and 6 of the grace
    for a teammate's number or inbox)

  Shares `UserEmails.from_address/0` and `UserEmails.support_phrase/0` so the
  whole mail surface keeps one sender and one support-contact policy.
  """

  import Swoosh.Email

  alias Fountain.Accounts.User
  alias Fountain.Emails.UserEmails
  alias Fountain.Mailer

  defp brand, do: UserEmails.brand()

  @doc """
  Welcome a just-verified user (#449).

  The first email that isn't a chore: everything before it is a verification
  link and everything after it is billing. Says what to do next (the console,
  which lists what is still missing) and, with billing on, what the opening
  credit is and how long it lasts.
  """
  @spec deliver_welcome_email(User.t()) :: {:ok, term()} | {:error, term()}
  def deliver_welcome_email(%User{} = user) do
    base_url = Fountain.PublicUrl.base()

    # The verified landing (ADR 0038): a key, one request, the reply. Not the
    # dashboard, which used to greet a new account with a checklist of things
    # to go and set up before anything could answer.
    start_url = "#{base_url}/start"

    opening_text = welcome_opening_phrase(user)
    # The same request the landing shows and the manual prints, with its
    # placeholders left in. The key is never in an email; the email says
    # where the key is.
    request = Fountain.Onboarding.curl(base_url: base_url)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Welcome to #{brand()}")
    |> html_body(welcome_html(start_url, opening_text, request))
    |> text_body(welcome_text(start_url, opening_text, request))
    |> Mailer.deliver()
  end

  # The opening grant (ADR 0031), in the welcome: what they start with and
  # how long it lasts. Nothing when billing is off.
  defp welcome_opening_phrase(%User{}) do
    if Fountain.Credits.enabled?() do
      cfg = Application.get_env(:fountain, :credits, [])
      cents = Keyword.get(cfg, :opening_cents, 500)
      days = Keyword.get(cfg, :opening_days, 14)

      "Your account starts with #{Fountain.Credits.format_cents(cents)} of credit, good for " <>
        "#{days} days — no card needed until then."
    end
  end

  defp welcome_html(start_url, opening_text, request) do
    """
    <!DOCTYPE html>
    <html>
    <body style="font-family: sans-serif; max-width: 600px; margin: 0 auto; padding: 24px;">
      <h2>Welcome to #{brand()}</h2>
      <p>
        Your account is verified. One request gets you a reply from an agent
        running in its own sandbox — no repository, no token, no install.
      </p>
      <pre style="background: #f4f4f5; border-radius: 6px; padding: 12px; font-size: 12px; overflow-x: auto;"><code>#{Phoenix.HTML.html_escape(request) |> Phoenix.HTML.safe_to_string()}</code></pre>
      <p>
        Your API key and your agent's id are on your start page, already
        filled into that request. Keys are shown once, so open it when you are
        ready to paste.
      </p>
      <p style="margin: 32px 0;">
        <a href="#{start_url}"
           style="background: #18181b; color: #fff; padding: 12px 24px; border-radius: 6px; text-decoration: none; font-size: 14px;">
          Get your key
        </a>
      </p>
      #{if opening_text, do: "<p>#{opening_text}</p>", else: ""}
      <p style="color: #71717a; font-size: 13px;">
        Or copy this link into your browser:<br/>
        <a href="#{start_url}" style="color: #3b82f6;">#{start_url}</a>
      </p>
    </body>
    </html>
    """
  end

  defp welcome_text(start_url, opening_text, request) do
    """
    Welcome to #{brand()}

    Your account is verified. One request gets you a reply from an agent
    running in its own sandbox — no repository, no token, no install.

    #{request}

    Your API key and your agent's id are on your start page, already filled
    into that request. Keys are shown once, so open it when you are ready to
    paste:

    #{start_url}
    #{if opening_text, do: "\n#{opening_text}\n", else: ""}
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
    |> subject("Your #{brand()} credit is running low")
    |> html_body(credits_html("Your credit is running low", balance, billing_url, false))
    |> text_body(credits_text("Your credit is running low", balance, billing_url, false))
    |> Mailer.deliver()
  end

  @doc """
  The prepaid balance is at or below zero: new work is refused until it is
  positive again (`Credits.gate/1`). Only sent while billing is on.
  """
  @spec deliver_credits_exhausted_email(User.t(), integer()) :: {:ok, term()} | {:error, term()}
  def deliver_credits_exhausted_email(%User{} = user, balance_cents) do
    billing_url = "#{Fountain.PublicUrl.base()}/account/billing"
    balance = Fountain.Credits.format_cents(balance_cents)

    new()
    |> from(UserEmails.from_address())
    |> to({user.email, user.email})
    |> subject("Your #{brand()} credit has run out")
    |> html_body(credits_html("Your credit has run out", balance, billing_url, true))
    |> text_body(credits_text("Your credit has run out", balance, billing_url, true))
    |> Mailer.deliver()
  end

  defp credits_consequence(true),
    do:
      "New conversations and new turns are paused until the balance is positive again. Anything already running finishes."

  defp credits_consequence(false),
    do: "Top up now so your agents keep working when it runs out."

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
        Credits you buy never expire and are spent after any credit that does.
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

    Credits you buy never expire and are spent after any credit that does.
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
