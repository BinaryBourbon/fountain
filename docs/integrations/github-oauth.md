# GitHub OAuth

**Optional.** Adds "Continue with GitHub" to the login and registration pages.
Email + password auth works without it.

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

One honest caveat: the GitHub button renders whether or not these are set.
Unconfigured, clicking it lands on a GitHub-side error page rather than an
in-app message.

## Behavior worth knowing

- **Only a GitHub-verified email is accepted.** Fountain checks the address's
  `verified` flag with GitHub rather than trusting the primary email, because
  sign-ins link to existing accounts by email — an unverified address set to
  someone else's email must not attach to their account. An unverified email
  is refused with a message telling the user to confirm it on GitHub first.
- OAuth signups arrive with their email already verified — no verification
  email is sent, so OAuth works fine on an instance with
  `EMAIL_DELIVERY=none`.
- `REGISTRATION_ENABLED=false` and `REGISTRATION_ALLOWED_EMAIL_DOMAINS` apply
  to OAuth signups too, not just the forms. Existing users can still sign in
  when registration is closed.

## Verify

Sign in with the button. The audit log (`/audit`) records
`auth.oauth.signup` or `auth.oauth.login`; rejections are recorded as
`auth.oauth.rejected` with the reason.
