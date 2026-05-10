# 0007 — G3: Go for public launch

**Status:** Accepted — 2026-05-10.

## Context

All four gates have been cleared:

- **G0** — Option B (API + Hosted UI + Self-Serve Onboarding) chosen.
- **G1** — Press-release narrative locked.
- **G2** — Architecture and engineering plan locked (26 open questions resolved).
- **G3** — Release validation complete. Two critical bugs (BUG-1: missing CLI token endpoint; BUG-2: onboarding redirect path 404) were identified and fixed before this gate. Ten non-critical issues were logged for the post-launch backlog.

Validation report: `plan/phase-3-release-validation/validation-report.md`.

## Decision

**Go.** Fountain is cleared for public launch as of 2026-05-10.

## Launch checklist (operator actions before flipping traffic)

1. Set all `sync: false` env vars in the Render dashboard: `MASTER_SECRETS_KEY`, `DATABASE_URL`, `SMTP_*`, `GITHUB_OAUTH_CLIENT_ID`, `GITHUB_OAUTH_CLIENT_SECRET`, `STRIPE_SECRET_KEY`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_WEBHOOK_SECRET`, `SPRITES_TOKEN`, `FOUNTAIN_DOMAIN`.
2. Create a Stripe product and at least one price in the Stripe dashboard; set the price ID in app config.
3. Register the Stripe webhook endpoint (`POST /api/stripe/webhook`) in the Stripe dashboard for events: `customer.subscription.created`, `customer.subscription.updated`, `customer.subscription.deleted`.
4. Register the GitHub OAuth app; set the callback URL to `https://<FOUNTAIN_DOMAIN>/auth/oauth/github/callback`.
5. Run `mix ecto.migrate` via Render’s `preDeployCommand` on first deploy (already wired).
6. Verify `POST /api/auth/token` + `fountain auth login` end-to-end with a test account before opening registration.
7. Set `users.role = "admin"` on the operator account directly in the DB after first registration.

## Post-launch backlog (non-blocking, first sprint)

- NC-1: Dark mode implementation
- NC-4: `Billing.sync_subscription/1` unit tests
- NC-5: `BillingLive` LiveView tests
- NC-6: Standardise `onboarding_completed_at` vs `onboarding_state`
- NC-9: `usage_events` user-deletion handling
- NC-2, NC-3, NC-7, NC-8, NC-10: cleanup and coverage gaps

## Consequences

- The success metric is 100 weekly active users by month 6 (2026-11-10).
- The product-analyst and growth-marketer roles are now available for post-launch measurement and growth experiments.
- Revisit org/team features (deferred per ADR 0003) once solo-user multi-tenancy is validated.
