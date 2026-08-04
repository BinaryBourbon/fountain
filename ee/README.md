# Fountain EE

Code in `ee/` is compiled into the same `:fountain` OTP app as everything
under `apps/fountain` (wired in via `elixirc_paths` / `test_paths` in
`apps/fountain/mix.exs`), but sits behind a directory boundary intended to
carry a different license in the future, GitLab-style. **Today it is MIT**
(`ee/LICENSE`, identical to the root license).

## Contents

- **Billing** — the Stripe integration: `Fountain.Billing`, the usage-event
  schema, the webhook controller, the billing LiveView, the billing Oban
  workers, and the `fountain.verify_lifecycle` mix task.
- **Transactional email** — `Fountain.Mailer`, `Fountain.Emails.UserEmails`,
  the email Oban workers (verification, welcome, account, email-change,
  lifecycle, trial-ending), the unverified-account pruner, and the email
  verification controller.

Module names are unchanged from their pre-move locations — only file paths
moved. See `decisions/0010-ee-directory-boundary.md` for the decision record.

## Boundary status

Core currently calls these modules directly; dependency-inversion seams and a
core-only (ee-less) build are deliberately future work, not yet built.

Known impurity: `ee/lib/fountain_web/live/billing_live.ex` also hosts the
account export/deletion UI (core functionality) pending extraction.
