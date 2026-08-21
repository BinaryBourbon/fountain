# GitHub OAuth

**Optional.** Adds "Continue with GitHub" to the login and registration pages.
Email + password auth works without it.

## At a glance

| | |
|---|---|
| Required | No |
| Provider | A GitHub OAuth app |
| Env vars | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` |
| Scope requested | `user:email` |
| Callback | `<PUBLIC_URL>/auth/oauth/github/callback` |
| Without it | Email and password auth only, with no dead-end button |

## Provider side

Create an OAuth app at
[github.com/settings/developers](https://github.com/settings/developers):

| Field | Value |
|---|---|
| Homepage URL | your `PUBLIC_URL` |
| Authorization callback URL | `<PUBLIC_URL>/auth/oauth/github/callback` |

The requested scope is `user:email`.

## Env vars

| Variable | Effect |
|---|---|
| `GITHUB_OAUTH_CLIENT_ID` | From the OAuth app |
| `GITHUB_OAUTH_CLIENT_SECRET` | From the OAuth app |

The button only renders when `GITHUB_OAUTH_CLIENT_ID` is set, so an
unconfigured instance shows plain email + password auth, with no dead-end
GitHub button.

## Behavior worth knowing

- **Only a GitHub-verified email is accepted.** Fountain checks the address's
  `verified` flag with GitHub rather than trusting the primary email, because
  sign-ins link to existing accounts by email, so an unverified address set to
  someone else's email must not attach to their account. An unverified email
  is refused with a message telling the user to confirm it on GitHub first.
- OAuth signups arrive with their email already verified, so no verification
  email is sent, so OAuth works fine on an instance with
  `EMAIL_DELIVERY=none`.
- `REGISTRATION_ENABLED=false` and `REGISTRATION_ALLOWED_EMAIL_DOMAINS` apply
  to OAuth signups too, not just the forms. Existing users can still sign in
  when registration is closed.

## Verify

Sign in with the button. The audit log (`/audit`) records
`auth.oauth.signup` or `auth.oauth.login`; rejections are recorded as
`auth.oauth.rejected` with the reason.

## Limits

**A GitHub outage breaks the button and nothing else.** Email and password
auth is unaffected, so an instance with both is not single-homed on GitHub.

**The button is all-or-nothing.** There is no per-user or per-domain gate on
who may use it, beyond `REGISTRATION_ALLOWED_EMAIL_DOMAINS`.

## Related

- [Nobody can log in](../troubleshooting/nobody-can-log-in.md), where OAuth is
  the way back in when mail is broken.
- [Put it on the internet](../guides/operate/put-it-on-the-internet.md).
- [Services Fountain uses](index.md).
