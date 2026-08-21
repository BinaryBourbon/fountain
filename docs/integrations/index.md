# Overview

The external services a Fountain instance talks to in order to run: where a
sandbox is provisioned, how mail goes out, who signs users in, whether spend is
metered, where errors land. These are the operator's business. One page per
service covers what to create on the provider side, which env vars result, and
how to verify it works.

This is the *outbound* half. For the tools that talk **to** a running Fountain
(editors, chat surfaces, plugins, SDKs) see
[Plugging into Fountain](clients.md); nothing there needs an env var here.

| Service | Required? | Env vars | Without it |
|---|---|---|---|
| [A sandbox provider](sandbox-contract.md) | **Yes, one of four** | `SPRITES_TOKEN` *or* `E2B_API_KEY` *or* `DAYTONA_API_KEY` (or users' own machines via [`fountain runner`](runners.md), no credential), plus `SANDBOX_PROVIDER` to pick the default | The app boots, but every conversation fails at provision time |
| [Mail](mail.md) | **A decision, yes** | `RESEND_API_KEY` *or* `SMTP_*` *or* `EMAIL_DELIVERY=none`, `EMAIL_FROM` | Production refuses to boot with none of the three set |
| [GitHub OAuth](github-oauth.md) | Optional | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` | Email + password auth only |
| [Stripe](stripe.md) | Optional | `BILLING_ENABLED`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_ID` | No billing. Correct for most self-hosted instances, so leave the gate off |
| [Sentry](sentry.md) | Optional | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | No error tracking; the SDK is inert and nothing leaves the instance |

The sandbox providers (Sprites, E2B, Daytona, and users' own machines) have
[a section of their own](sandbox-contract.md): one contract, four
implementations. The row above is the short version.

## The service you do not configure

**Inference providers, meaning Anthropic, OpenAI and Gemini, are not set up by the
operator.** There is no platform-level API key: each user brings their own
credentials, entered at `/account/inference-credentials` in the running app
(an Anthropic API key or Claude Code OAuth token, an OpenAI API key, a Gemini
API key, validated against the provider on save, stored encrypted per
tenant, and never echoed back). With both Anthropic credentials on file the
OAuth token is the one used, which bills a subscription rather than metered
usage. See [which credential claude uses](../catalog/runtimes/claude.md#which-credential-it-uses).

This is a deliberate design
([ADR 0008](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0008-byo-inference-credentials.md)):
inference cost scales with usage and belongs to the person using it, and many
users want their own Claude subscription doing the work. If you are looking
for where to put `ANTHROPIC_API_KEY` in the server environment, there is
nowhere, on purpose.
