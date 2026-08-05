# Mail

**A decision is required.** Production refuses to boot with no mail setting,
because a silently discarded verification email dead-ends signup with no
visible error. There are exactly three options, checked in this order:

## Option 1: Resend

| Variable | Effect |
|---|---|
| `RESEND_API_KEY` | Delivery via [Resend](https://resend.com) |

Provider side: verify your sending domain in Resend (SPF, DKIM, DMARC
records) before pointing `EMAIL_FROM` at it — an unverified domain will not
deliver to arbitrary inboxes.

## Option 2: any SMTP server

| Variable | Default | Effect |
|---|---|---|
| `SMTP_HOST` | — | Selects SMTP delivery |
| `SMTP_PORT` | `587` | |
| `SMTP_USERNAME` | — | Omit entirely for an unauthenticated relay |
| `SMTP_PASSWORD` | — | |
| `SMTP_TLS` | `always` | STARTTLS by default; `never` for a relay on a trusted network that does not offer it |

If `RESEND_API_KEY` is also set, Resend wins — the options are checked in
order.

## Option 3: no email, deliberately

| Variable | Effect |
|---|---|
| `EMAIL_DELIVERY=none` | Disables email with a stderr notice at boot |

For an OAuth-only instance, or while evaluating. Accounts created with email
+ password self-verify at registration — a verification link that can never
be delivered gates nothing (ADR 0011).

Password reset is dead in this mode; the only route back into a locked-out
account is operator intervention.

## In every mode

| Variable | Default | Effect |
|---|---|---|
| `EMAIL_FROM` | — (required) | The From address, on a domain your provider is verified for. Required with any real delivery provider — the app refuses to boot without it rather than sending mail your provider will reject |

What actually sends email today: account verification (24-hour link),
password reset (1-hour link), and — only with [Stripe](stripe.md) configured
— the four lifecycle emails: the trial-ending reminder three days out,
trial expired, payment failed, and subscription canceled. OAuth signups skip verification
entirely, so [GitHub OAuth](github-oauth.md) plus `EMAIL_DELIVERY=none` is a
coherent minimal setup.

## Verify

Register a throwaway account and confirm the verification email arrives —
check spam, which is where an unverified sending domain lands. On a running
instance, boot logs state the chosen mode (`EMAIL_DELIVERY=none` prints its
notice to stderr; a missing configuration refuses to boot and says so).
