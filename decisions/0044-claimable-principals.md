---
type: ADR
title: "Claimable principals: an anonymous computer that survives registration"
description: "A trusted application opens a short-lived users row as a claimable principal; claiming attaches a registered account as its owner, so the principal id — and every sandbox, agent and conversation keyed to it — never changes."
tags: [api, security, billing, sandbox, accounts]
status: stable
adr: "0044"
adr_status: "Accepted"
date: 2026-09-04
generated: { by: human:jhgaylor, at: 2026-09-04T00:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-04T00:00:00-04:00 }
---

# 0044 — Claimable principals: an anonymous computer that survives registration

**Status:** Accepted. Built in #1551.

## Context

An application built on Fountain wants to start a computer for a first-time
visitor before that visitor has an account, and then let them keep it. Paddock
(`managoat/demos`, issue 14) is the first: opening the app should start
Terminal 1 immediately, and registration should become an optional action
rather than the gate in front of the product.

Two facts about Fountain make this harder than it sounds.

The first is that **the tenant is part of sandbox identity**. A sprite's name is
minted as `fountain-<first eight characters of the user id>-<random>`
(`Fountain.Conversations`), and a self-hosted runner's name carries its runner
(ADR 0022). The name is the only thing the adapter is handed (ADR 0018), so it
is the machine's identity at the provider. Every row in the system — agents,
environments, vaults, conversations, sandboxes, the credit ledger, the audit
trail — is scoped by `user_id`. A resource-by-resource transfer API that
re-parents those rows onto a different user therefore does not move the
computer; it builds a second one and abandons the first, which is precisely
what the application asked not to happen.

The second is that **one shared service account is not isolation**. If every
anonymous visitor were a row under one Fountain user, the application would
have to become a multi-tenant isolation and billing layer over a single
account, re-implementing the tenant-scoping contract Fountain already enforces
at the query level, and any visitor holding that credential would reach every
other visitor's machine.

So Fountain needs a principal that is a first-class tenant from the first
request, whose identity does not move when someone registers.

## Decision

**A claimable principal is a real `users` row.** Not a new concept beside the
user, not a sub-tenant, not a namespace: a row in `users` with
`principal: true`, no email and no password, created by a trusted application
and torn down on a timer if nobody claims it. Because it is a user, tenant
scoping, envelope encryption, quotas, the credit ledger and the audit trail all
apply to it by construction, and its id — the `principal_id` the application
holds — is the id already baked into every sandbox name.

**Claiming attaches an owner; it never moves a resource.** A new
`principal_owners` row records that a registered account owns the principal.
The principal row keeps `principal: true` and stays identity-less forever: it
is a workspace, not a person. Nothing about the machine changes at the moment
of claim — same sandbox, same disk, same agent, same conversations, same ids —
because nothing about the machine is touched.

This is what makes the two claim paths one path. A brand-new account and an
existing account both claim by becoming the owner of a principal they did not
previously own, which is the "an account can hold more than one principal"
shape the problem demands. It is also why claiming is not a merge: two `users`
rows are never folded together, so an existing account claims without
abandoning what it already has.

**Six mechanisms follow from that:**

1. **The application is a Fountain account.** There is no separate application
   credential store. A trusted application authenticates with an ordinary
   full-scope API key belonging to its own Fountain account, and every
   principal it opens records `application_user_id`. Billing attribution,
   audit attribution, rate limiting and the outstanding-principal cap are then
   the account-level mechanisms Fountain already has.

2. **A new `principal` API-key scope.** Beside `full` and `sprite`
   (`Fountain.Accounts.ApiKey`). It is not in `@key_management_scopes`, so
   every route behind `:require_full_scope` — billing, account settings, API
   keys, connections, inference credentials, runners, webhooks, secret
   bindings, admin, and the `claimable-users` surface itself — refuses it with
   `insufficient_scope`. What is left is exactly the resource surface a
   computer is built and operated from: agents, environments, vaults,
   conversations, sandboxes, events and the team. A principal therefore cannot
   mint a further credential, widen its own limits, or see another principal.

3. **The budget is a credit grant, and the live-sandbox cap is the override
   that already exists.** Creating a principal moves `max_cost_usd` from the
   application's balance into the principal's ledger (a `burn_grant` on the
   application, a `grant_application` on the principal), and writes
   `max_live_sandboxes` to `users.sandbox_limit_override`. So budget
   exhaustion is `Billing.check_spend/1` refusing at every door that spends
   (ADR 0031), and concurrency is `Fountain.Quotas` unchanged. Releasing an
   unclaimed principal expires its remaining lot and refunds the application.

4. **After a claim, the owner's ledger funds the work.**
   `Fountain.Principals.billing_subject_id/1` resolves a claimed principal to
   its owner and everything else to itself. The credit gate reads the subject's
   balance and `CreditPricer` posts the burn against the subject, so usage
   before a claim lands on the application's introductory grant and usage after
   it lands on the registered account — with no ledger row ever moving.

5. **Claim and expiry serialize on one row.** Both take `SELECT … FOR UPDATE`
   on the `claimable_users` row inside a transaction, so exactly one wins:
   two competing claims produce one success and one `409 already_claimed`, and
   a claim that beats the expirer by a millisecond is a claim. Eligibility of
   the claiming account is checked *before* anything is mutated, so a refused
   claim leaves the provisional principal exactly as it was, still usable by
   the credential the application holds.

6. **Idempotency keys live on the row, not in a side table.** The create key is
   unique per application; the claim key is stored on success. Replaying either
   with the same key returns the same principal and mints a **fresh**
   credential, because the secret from the first response was never stored.
   That is also the rotation path for a claimed principal's credential.

**The API is four routes**, all behind `:require_full_scope`:
`POST /api/claimable-users`, `GET /api/claimable-users/:id`,
`POST /api/claimable-users/:id/claim` and `DELETE /api/claimable-users/:id`.

## Consequences

**The console does not show an owned principal.** Every console query is scoped
to `current_user.id`, and an owner is a different row from the principal it
owns. So a human who claims a principal operates it through the API with the
credential the claim returned, and sees nothing of it in Fountain's own
operator console until a principal switcher is built. This is the price of not
merging accounts, and it is the honest reading of "an account owns more than
one principal": Fountain now has a concept the console has no word for. The
`GET /api/claimable-users/:id` reconcile route is what an owner has instead.
Tracked as #1566 — a gap, not the intended end state.

**`billing_subject_id/1` is a new indirection on the spend path.** It is one
indexed lookup, skipped entirely for a `%User{principal: false}` — which is
every ordinary account — but it means the ledger a burn lands on is no longer
always the `user_id` on the turn. Anything that reconciles usage against the
ledger has to resolve the subject the same way. `Fountain.Billing.record_usage`
deliberately does **not**: usage events record what the principal did, and only
money follows the owner.

**A principal is a `users` row, so anything that counts `users` now counts
principals.** Two places had to stop. The activation funnel
(`Fountain.Funnel`) reads registrations, and a principal never verifies, so
every one of them would sit in `registered` forever and pull every conversion
rate below it down — a growth metric moved by how many anonymous visitors an
application opened. The finance overview's account counts are the other: a
principal is not an account somebody holds, and its balance is not a second
sale, because the money in it came out of the balance of the application that
bought it. `Finance.deferred_cents/0` deliberately still counts it — the
transfer is balance-neutral, and unspent credit is owed whichever row holds
it — and the per-tenant finance table still lists a principal that ran turns,
because that is a real cost with a real provider bill behind it.

**Deleting an account deletes the principals it owns.** The ownership row
cascades either way, so the alternative is not to keep the principal but to
leave a tenant with resources, no owner, no credential that reaches it and no
sweep that would ever find it.

**A principal is an unverified account that must never be pruned.**
`UnverifiedAccountPruner` deletes accounts that registered and never verified,
and a principal has `email_verified_at: nil` forever. It now excludes
`principal: true` rows; the claimable expirer is what reaps those, on its own
schedule and with a refund the pruner would not have made.

**`authenticate_api_key/1` gains a second way to pass.** The `:unverified`
refusal (#533) was a single invariant — no verified email, no API. It is now
"verified, or a principal". That is one more branch on the hottest auth path in
the system, and the reason the branch reads the preloaded `user.principal`
column rather than asking another table.

**Anonymous compute is a spend surface.** An application with a full-scope key
can open principals in a loop, each funded from its own balance. The balance is
the backstop — an application cannot grant what it does not hold — and on top
of it sit a per-application outstanding-principal cap and a creation rate
limit. Neither is a substitute for watching the application's ledger.

## Alternatives considered

- **Resource-by-resource transfer (`POST /api/transfers`)** — re-parents each
  agent, environment, vault and conversation onto the registering account. It
  changes the `user_id` component of every sandbox name, so the machine the
  visitor was watching is not the machine they end up with. This is the failure
  the issue was written to avoid.
- **Identity merge: move the email onto the principal row.** Claiming would set
  `email` and `password_hash` on the provisional row and tombstone the
  registering one, giving a single concept and no `principal_owners` table. It
  works only when the claiming account is brand new and empty; an existing
  account with its own agents cannot claim without abandoning them, so half the
  requirement goes unmet.
- **One shared service account per application.** Rejected in Context: it makes
  the application the isolation boundary for data Fountain is already scoping,
  and one leaked visitor credential reaches every visitor.
- **A `principals` table beside `users`.** A cleaner name, and every context in
  the system would have to learn about it — the tenant-scoping contract, the
  crypto DEK derivation, quotas, credits and audit are all written against
  `user_id`. The rename buys clarity and costs a rewrite of the thing the
  clarity is about.
- **A separate application-credential registry, like `OAUTH_CLIENTS`.** A
  config-file list of applications with their own secrets. It would need its
  own audit attribution, its own rate limiting and its own funding source, none
  of which a Fountain account needs to be given.
