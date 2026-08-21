# Configure email

This guide shows you how to pick a mail setting, which is a decision Fountain
requires rather than an optional extra.

Fountain refuses to start in production without one, because a silently
discarded verification email dead-ends signup with no visible error.

## Pick one of three

| Setting | Effect |
|---|---|
| `RESEND_API_KEY` | Delivery via Resend |
| `SMTP_HOST` (plus `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD`) | Any SMTP server. Port defaults to 587 with STARTTLS. Omit the username for an unauthenticated relay |
| `EMAIL_DELIVERY=none` | No email. Accounts self-verify at registration (ADR 0011) |

`EMAIL_FROM` sets the sender in the first two modes.

## What each choice costs you

Password reset also needs working mail. With `EMAIL_DELIVERY=none` the only
route back into a locked-out account is the database.

That is the trade the mode's boot notice warns about, and it is usually the
right trade for a single-operator instance where you can run a release task.

Provider-side setup, including domain verification and what each mode means for
signup, is in the [mail integration guide](../../integrations/mail.md).

## Verify it worked

Register a throwaway account and watch for the verification mail. If it does
not arrive, verify the account by hand and treat that as a failing mail setup
rather than a fix.

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("them@example.com")'
```

## If it did not work

An unverified sending domain (SPF, DKIM, DMARC) is accepted by the provider and
then rejected or spam-foldered downstream. See
[Nobody can log in](../../troubleshooting/nobody-can-log-in.md).

## Related

- [Mail integration guide](../../integrations/mail.md), for provider setup.
- [Run a release task](run-a-release-task.md), for `verify_email/1`.
- [Nobody can log in](../../troubleshooting/nobody-can-log-in.md).
