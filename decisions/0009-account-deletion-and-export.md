---
type: ADR
title: "Account deletion and data export"
description: "Account deletion is immediate and ordered, aborting only if Stripe cancellation fails; export covers what deletion erases. Documents behavior built in #170, #288 and #450."
tags: [accounts, privacy, billing]
status: stable
adr: "0009"
adr_status: "Accepted"
date: 2026-08-03
generated: { by: human:jhgaylor, at: 2026-08-03T16:55:10-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-03T16:55:10-04:00 }
---

# 0009 — Account deletion and data export

**Status:** Accepted (documents behavior built in #170/#288 and refined through #450; nothing described here is unbuilt)

## Context

Deletion and export encode business and legal commitments — GDPR-style
erasure scope, invoice retention, what "unrecoverable" means — but the
reasoning lived only in the `Fountain.Accounts.Deletion` and
`Fountain.Exports` moduledocs. Those are good, but a moduledoc reads as
implementation detail: nothing marked these as decisions future work must not
casually reverse, and the 2026-08-03 story assessment (#453) flagged exactly
that. This ADR promotes the decisions; the moduledocs keep the mechanics.

## Decision

**Deletion is immediate, ordered, and fails toward keeping the account.**
`Deletion.delete_user/2` is the single path for all three triggers (self-serve
with typed-email confirmation, admin, unverified-account pruner):

1. **Stripe cancellation first, and it is the only aborting step.** Deleting
   the local account while Stripe keeps charging is unrecoverable — the user
   no longer has an account to cancel from — so a cancellation failure stops
   everything.
2. Sprite destruction, best-effort (`SandboxReaper` reconciles stragglers).
3. Audit event before the delete, with email and user id denormalized into
   metadata, because `audit_events.user_id` nilifies on delete.
4. Row delete. Cascades take agents, api_keys, conversations (turns, log
   events), environments, vaults, oauth_identities, inference_credentials
   and `user_data_keys`; `usage_events`, `audit_events` and `sandboxes`
   nilify, keeping operational and financial history that names nobody.

**Crypto-shred, with an honest boundary.** Deleting `user_data_keys` destroys
the wrapped per-tenant DEK, so ciphertext that outlives the cascade is
undecryptable rather than merely unreferenced. This does **not** reach
database backups taken before the deletion; backup expiry (14 days) is what
erases those, on its own schedule. User-facing copy must not promise more
than this.

**The Stripe customer is retained; only subscriptions are cancelled.**
Invoices are financial records a business must keep, and Stripe is their
system of record. Deleting the customer would destroy an accounting trail we
are obliged to retain.

**There is no soft-delete or grace window — deliberately.** The mitigations
are up front instead: a typed-email confirmation, the export nudge beside the
delete button, and a confirmation email after the fact. A reactivation window
would require retaining the DEK, which hollows out the crypto-shred promise —
"deleted" would mean "recoverable by us for N days", which is a different
product promise. Revisit only with that trade-off on the table.

**Export is the other half: export-then-delete, not delete-and-trust.**
Self-serve from the account page, one request per hour, built async, TTL'd
download. The export covers everything the account owns **except secret
values** — environment and vault secrets are write-only on the way in and
stay that way on the way out (names only, never plaintext, never ciphertext).

**Who gets told.** Deletion sends a confirmation email to the departing
address — but only if it was verified, which also keeps the pruner path
silent: an address that never proved it was someone's gets no mail from us
regardless of who triggered the deletion (#450).

## Consequences

- Support cannot "undo" a deletion; the answer to that ticket is the backup
  retention window and a restore drill, not an app feature.
- Legal/GDPR questions have one page to point at, and changes to any of these
  properties (retention windows, shred scope, customer retention) are ADR
  amendments, not incidental code review comments.
- The moduledocs stay authoritative for mechanics and now point here for the
  why.

## Alternatives considered

- **Soft-delete with a 30-day reactivation window** — requires retaining the
  DEK, which converts "deleted" into "recoverable by the operator", a weaker
  promise than the one we make. Rejected while crypto-shred is the promise.
- **Deleting the Stripe customer too** — destroys invoice history we are
  required to keep. Rejected.
- **Including decrypted secrets in the export** — would make the export
  artifact the most dangerous file the product produces, sitting in a
  download directory. Secrets are reproducible by their owner; conversations
  are not. Rejected, and stated in the UI.
