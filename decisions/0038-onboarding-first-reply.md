---
type: ADR
title: "Onboarding is the path from verified to first reply, carried by the API"
description: "The primary audience is the developer integrating the API; activation is the first conversation with a reply, from any door; the path is a key and one request handed over on the verified landing against a default agent that runs on platform inference metered against credits (amending 0008); the CLI is the second door with `auth register`. Decided 2026-09-02; nothing is built yet."
tags: [onboarding, product, billing, inference, cli, analytics]
status: draft
adr: "0038"
adr_status: "Accepted"
date: 2026-09-02
generated: { by: human:jhgaylor, at: 2026-09-02T14:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-02T14:00:00-04:00 }
stale_after: 2026-11-02
---

# 0038 — Onboarding is the path from verified to first reply, carried by the API

**Status:** Accepted, 2026-09-02. The implementation issues are #1388
(platform inference), #1389 (the default agent), #1390 (the verified landing),
#1391 (the CLI's `auth register` and `quickstart`), #1392 (activation redefined
and measured) and #1393 (the field cleanup), all sub-issues of #1039. Each PR
that builds one updates this block.

**Built so far:** decisions 2 (#1392), 3 (#1388), 4 (#1389), 5 (#1426) and
7 (#1393).

Decision 2: `Fountain.Activation` holds the definition, `Fountain.Funnel`
counts it and measures verification to first reply, and
`activation.first_reply` reaches PostHog from the turn-ending write.

Decision 3: `PLATFORM_ANTHROPIC_API_KEY` / `_OPENAI_` / `_GEMINI_` (blank is
off, per provider), `Fountain.InferenceCredentials.select/2` as the one
selection rule, a `burn_inference` debit per closed platform turn from
`Fountain.Credits.InferenceRates` posted by `Workers.CreditPricer`, and
`PLATFORM_INFERENCE_DAILY_CENTS` (default 5000) as a deployment-wide daily
circuit breaker answering 503.

**The price is pass-through at provider list, a 1.0x margin, no markup**
(decided with Jake on 2026-09-02). Fountain's margin is sandbox time
(`CREDIT_TURN_HOUR_CENTS`, [0031](0031-credits-are-the-product.md)). Marking
inference up would make the opening credit buy less of the one thing it was
granted to buy, which is the reply this ADR is about. A future decision may
change that; a passing thought about margin should not.

Decision 4: `Fountain.Agents.Starter` is planted by `Accounts.verify_email/2`,
so an account verified from now on owns one agent from the moment it is
verified.

Decision 5: `FountainWeb.StartLive` is the verified landing at `/start`. It
mints an API key and shows it once, prints one request against the account's
agent from the single source `Fountain.Onboarding` shares with
`docs/quickstart.md`, and shows the reply inline. Both signup routes land
there. The dashboard checklist is gone.

Decision 7, both halves. `Fountain.Activation` stamps
`onboarding_completed_at` at the first reply rather than a console page
(#1426), and `users.onboarding_state` is dropped (#1393) along with
`Accounts.advance_onboarding/2`, the funnel's `by_onboarding_state`
breakdown, and the field on `GET /api/auth/me` and
`GET /api/account/onboarding`. The stamp is the whole of onboarding. Both
onboarding endpoints still work: only the vestigial field went, because
whether `POST /onboarding/complete` has a purpose left now that the stamp
moved is a question about the landing, not about this cleanup. This settles
NC-6 from [0007](0007-g3-launch-go.md).

Not built: the CLI commands (#1391).

Amends [0008](0008-byo-inference-credentials.md): Fountain will hold platform
inference keys. Leans on [0031](0031-credits-are-the-product.md) (the opening
credit and the balance gate), [0030](0030-prepaid-credits.md) (the ledger),
[0003](0003-direction-option-b-api-ui-onboarding.md) (an API product with a
hosted console), [0021](0021-oauth-for-first-party-apps.md) and #1305 (device
login, which is what makes the CLI able to finish a sign-up), and #1010
(canned agents, `fountain apply`). Settles NC-6 from the launch backlog
([0007](0007-g3-launch-go.md)).

## Context

#1039 asked what onboarding is before anyone built more of it, because what
exists accreted: signup and verification, a welcome email, a three-item
dashboard checklist (a credential, an agent, a conversation), a docs index
box that installs the CLI and logs in, a guided tour that needs an API key, a
repository and a GitHub token, the SDK, the CLI, the catalog. Four surfaces
each describe a different first hour and each ends by sending the developer
to one of the others.

The funnel on 2026-08-23 said 45 verified accounts, 38 of which created
nothing. On 2026-09-02, after the unverified accounts were pruned: 49
verified, 40 created nothing, 9 ever started a conversation, of which 3 are
internal and the rest are friends. Signups run at two or three a week. The 40
are almost certainly bot traffic; the honest reading is that there is not yet
an active user who is not the maintainer or a friend, so the current numbers
cannot judge a design. What can is a test anyone can run: from a blank
account with nothing but an email address, how long until a reply.

Two things in the accreted path cost the developer before the product has
done anything. Inference credentials are bring-your-own (0008), so the first
screen asks for an Anthropic key before there is anything to run. And there
is no zero-prerequisite hello world: the shortest documented path needs a
repository and a GitHub token. Meanwhile the opening credit (0031) already
pays a stranger's sandbox time on the argument that the first run must cost
them nothing; inference is the second cost on the same first run.

## Decision

1. **The primary audience is the developer integrating the API.** The
   operator self-hosting and the person evaluating in ten minutes get a
   signpost from the path, not a path of their own.

2. **Activation is the first conversation with a reply**, from any door: a
   request from the developer's own code, the SDK, the CLI, or the
   conversations app. `Fountain.Funnel` and the PostHog funnel both measure
   it as the earliest turn with a reply, and the number the redesign is
   judged on is **time from verification to first reply** (median and p90)
   and the share of verified accounts that reach it within a day, measured
   from the day the landing ships. A conversation with no reply does not
   count. (#1392)

3. **Fountain holds platform inference keys and runs a tenant's agent on
   them when the tenant has no credential of their own, metered against the
   tenant's credit balance.** This amends 0008. The tenant's own credential
   always wins when present; a deployment with no platform key behaves
   exactly as before, so self-hosters opt in. Token usage is priced into the
   ledger as a debit per closed turn beside sandbox time, the balance is the
   gate, and a per-deployment daily ceiling is the circuit breaker. The
   opening credit is what caps a stranger. (#1388)

4. **Every account has a default agent from the moment it is verified**, a
   canned agent on the claude runtime created beside the opening credit,
   ordinary in every way (listed, editable, deletable, never recreated). It
   exists so there is something to send the first request to. (#1389, built:
   `Fountain.Agents.Starter`, planted by `Accounts.verify_email/2` and audited
   as `system:onboarding` per [0013](0013-audit-trail.md).)

5. **The path is a key and one request, and the API carries it.** The first
   screen after verification hands the developer their API key and one
   copyable request against the default agent (`curl` and the SDK
   equivalent, from one source), shows the reply on that screen when it
   comes, names that moment as activation, and offers three doors below:
   add your own inference key, `fountain apply` for your own agents, the SDK
   for real code. The three-item checklist goes. The docs quickstart is the
   same request with placeholders and says where the key is; the tour is the
   second page; the welcome email links to the landing. The console does not
   onboard; it hands off. (#1390)

6. **The CLI is the second door, and it does the steps rather than
   describing them.** `fountain auth register` creates the account through
   the existing `POST /api/auth/register`, waits for verification by polling
   the token endpoint until it stops answering `email_unverified`, saves the
   key and prints the same request the landing shows; `fountain quickstart`
   runs it. The CLI is not required for the path, since installing anything
   is a cost the primary audience should not pay to see a reply. (#1391)

7. **`onboarding_completed_at` is the one onboarding field**, stamped at
   first reply. `onboarding_state` is dropped. (#1393)

The path, counted: verify, copy, run, reply. Four steps, none on another
site. Adding a credential is the fifth, and it is the first one the
developer takes because they want to, not because nothing works without it.

## Consequences

- **A billing decision is inside an onboarding decision**, and it is the
  one with a cost. Platform inference spend is real money against a $5
  opening credit; the finance panel has to show the margin, the daily
  ceiling has to exist before the key does, and a bad day is bounded by a
  number written in config. The metering lands in the same ledger and the
  same pricer as sandbox time (0030, 0031), which is why it is tractable.
- **0008's premise is gone**: Fountain now pays for inference for accounts
  that have not supplied a key. The per-tenant DEK, the BYO path and "the
  tenant's credential wins" are unchanged; what changes is the default when
  there is none.
- **Twenty-odd tests that count a new account's agents change**, and
  `insert_verified_user/1` creates an agent. Every test that assumed an empty
  verified account is touched once; the ones whose subject is a controlled set
  of agents take the new `insert_user_without_agents/1` instead. Two of them
  are not arithmetic: the funnel's stalled breakdown now reports "built an
  agent" for every stalled account and "built nothing" for none, and the
  dashboard checklist's agent step arrives ticked. #1421 and #1390 own those
  two surfaces respectively; #1389 left both computing what they always did,
  and the tests assert the degenerate numbers rather than hiding them. #1421
  waits for #1390 so that the replacement decomposition is chosen against the
  funnel's final shape.
- **Activation counted through turns instead of conversations** will report
  fewer activated accounts than today's funnel, since conversations that
  never answered stop counting. That is the point; the PR that changes it
  records both numbers.
- **The console loses its first screen's purpose.** The dashboard becomes
  an operator's dashboard again after the first reply; the landing is a
  handoff, not a home.
- **The CLI doing sign-up makes bot sign-up easier** than a form with a
  browser in front of it. The rate limits and anti-enumeration rules on the
  two endpoints already exist and apply; nothing is created for an account
  until it verifies, and the platform key is behind the balance gate. If
  bot traffic becomes a cost, the lever is the opening grant, not the CLI.
- **The top of the funnel is not addressed here**, deliberately. This ADR
  makes the first hour short and measurable so that when strangers arrive,
  the number means something.

## Alternatives considered

- **Onboarding is docs.** The docs are good after the IA rebuild and the
  STE pass, and the accounts that verified created nothing rather than
  failing at step two; docs describe, they cannot remove the credential
  wall or run the first request.
- **A read-only demo agent on Fountain's key, no metering.** Cheaper to
  build, and it leaves the first real run behind the same wall; the
  developer would activate on a toy and stall on their own agent. Metering
  the real thing is the same code with a price on it.
- **"Connect your Claude account" instead of platform keys.** The
  `claude_code_oauth_token` credential exists, but obtaining it is a
  paste after a CLI login on Anthropic's side, not an OAuth flow Fountain
  can start; it is a better paste step, not the removal of the step.
- **The CLI as the primary carrier.** It can do steps rather than describe
  them, which is why it is the second door, but it requires an install,
  the Linux install has a known trap (#1327), and a developer evaluating an
  API should be able to see a reply without installing anything.
- **The console checklist, kept and improved.** It defines done as "three
  things exist", which is not activation, and it sends the third item to a
  different origin to click a button.
- **Do nothing until strangers arrive.** The number would still be
  unmeasured when they did.
