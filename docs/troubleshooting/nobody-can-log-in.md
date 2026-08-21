# Nobody can log in

This guide shows you how to work down the chain from the most common cause to
the least.

Note the symptom, because it misleads. The password is accepted and the session
is real, but it never leaves the "check your email" page, so this reads as a
broken app rather than a refused login.

## 1. Did the verification email go anywhere?

An instance with `EMAIL_DELIVERY=none` sends nothing, and that is the compose
default.

Verify an account by hand.

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.verify_email("them@example.com")'
```

If that unblocks the account, the problem is mail. See
[Configure email](../guides/operate/email.md).

## 2. Mail configured but not arriving

An unverified sending domain (SPF, DKIM, DMARC) is accepted by the provider and
then rejected or spam-foldered downstream. See the
[mail integration guide](../integrations/mail.md).

## 3. OAuth still works when mail does not

GitHub sign-ins arrive already verified, so they are a way back in while mail
is broken.

Conversely, a GitHub outage breaks only the button. Password auth is
unaffected.

## 4. Password reset needs working mail

With `EMAIL_DELIVERY=none` a locked-out password account has no self-serve
route back. That is the trade-off the mode's boot notice warns about, and the
only route is a release task.

## 5. 429 responses

The API rate limit is 600 requests per minute per IP.

If *everyone* is rate-limited at once behind a proxy, `TRUSTED_PROXIES` is
unset and every client is sharing the proxy's bucket. See
[Put it on the internet](../guides/operate/put-it-on-the-internet.md).

## Related

- [Configure email](../guides/operate/email.md).
- [Run a release task](../guides/operate/run-a-release-task.md), for
  `verify_email/1` and `promote_admin/1`.
- [Mail integration guide](../integrations/mail.md).
