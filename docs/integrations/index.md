# Integrations

Every external service a Fountain instance can talk to, what it is for, and
what breaks without it. One page per integration covers what to create on the
provider side, which env vars result, and how to verify it works.

| Integration | Required? | Env vars | Without it |
|---|---|---|---|
| [A sandbox provider](sandbox-contract.md) | **Yes — one of three** | `SPRITES_TOKEN` *or* `E2B_API_KEY` *or* `DAYTONA_API_KEY`, plus `SANDBOX_PROVIDER` to pick the default | The app boots, but every conversation fails at provision time |
| [Mail](mail.md) | **A decision, yes** | `RESEND_API_KEY` *or* `SMTP_*` *or* `EMAIL_DELIVERY=none`, `EMAIL_FROM` | Production refuses to boot with none of the three set |
| [GitHub OAuth](github-oauth.md) | Optional | `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET` | Email + password auth only |
| [Stripe](stripe.md) | Optional | `BILLING_ENABLED`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`, `STRIPE_PRICE_ID` | No billing. Correct for most self-hosted instances — leave the gate off |
| [Sentry](sentry.md) | Optional | `SENTRY_DSN`, `SENTRY_ENVIRONMENT` | No error tracking; the SDK is inert and nothing leaves the instance |

## The integration with nothing to configure

All three ACP clients below spawn the same adapter; its protocol surface,
`_meta` extensions and failure modes are on one page,
[**`fountain acp` (reference)**](acp.md), so the client pages only cover setup.

[**Editors**](editors.md) are the one integration an operator does not set up.
An ACP-capable editor — Zed and friends — spawns `fountain acp` locally and
talks to your instance with the credentials the developer already has. There is
no env var, no server-side switch, and nothing for you to run: it works against
any instance the CLI can reach.

[**OpenClaw**](openclaw.md) reaches the same `fountain acp` adapter from a chat
surface — Telegram, Discord, Slack — by registering Fountain as a custom ACP
agent in its `acpx` plugin. Again there is nothing to change on the Fountain
side; the configuration is client-side, on the OpenClaw host.

[**Buzz**](buzz.md) is the other direction: Fountain *hosts* a Buzz agent —
a Nostr identity that lives on a relay — running its coding agent in a sandbox
and holding its signing key in a vault. Provision one from the Buzz desktop or
`POST /api/buzz/agents`; it self-enables on any image that ships the `buzz-acp`
binary.

The sandbox providers — Sprites, E2B, Daytona — have
[a section of their own](sandbox-contract.md): one contract, three
implementations.

## The integration you do not configure

**Inference providers — Anthropic, OpenAI, Gemini — are not set up by the
operator.** There is no platform-level API key: each user brings their own
credentials, entered at `/account/inference-credentials` in the running app
(an Anthropic API key or Claude Code OAuth token, an OpenAI API key, a Gemini
API key — validated against the provider on save, stored encrypted per
tenant, and never echoed back).

This is a deliberate design
([ADR 0008](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0008-byo-inference-credentials.md)):
inference cost scales with usage and belongs to the person using it, and many
users want their own Claude subscription doing the work. If you are looking
for where to put `ANTHROPIC_API_KEY` in the server environment — there is
nowhere, on purpose.
