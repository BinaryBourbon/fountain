# Fountain EE

Code in `ee/` is compiled into the same `:fountain` OTP app as everything
under `apps/fountain` (wired in via `elixirc_paths` / `test_paths` in
`apps/fountain/mix.exs`), but sits behind a directory boundary intended to
carry a different license someday, GitLab-style — an option preserved, not a
plan of record. **Today it is MIT** (`ee/LICENSE`, identical to the root
license).

## Contents

- **Billing** — the Stripe integration: `Fountain.Billing`, the usage-event
  schema, the webhook controller, the billing LiveView, the
  `stripe_customer_sync` worker, and the `fountain.verify_lifecycle` mix task.
- **Billing-adjacent / growth email** — `Fountain.Emails.BillingEmails`
  (welcome, trial, payment-lifecycle mail) and the `welcome_email`,
  `trial_ending_email`, `lifecycle_email` workers.

Account email (verification, password reset, suspension/deletion notices,
email change) and `Fountain.Mailer` are **core** — a community instance must
never depend on ee/ for mail it actually needs (#475/#476). See
`decisions/0010-ee-directory-boundary.md` and its 2026-08-05 addendum.

## Boundary status

Core currently calls these modules directly; dependency-inversion seams and a
core-only (ee-less) build are deliberately future work, not yet built.

Known impurity: `ee/lib/fountain_web/live/billing_live.ex` also hosts the
account export/deletion UI (core functionality) pending extraction.
