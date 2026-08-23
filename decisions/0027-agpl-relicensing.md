---
type: ADR
title: "AGPL-3.0 for the server, Apache-2.0 for the clients, Elastic 2.0 for ee/"
description: "Fountain relicenses from MIT before the commercial launch: AGPL-3.0-or-later on apps/fountain so a hosted fork owes its changes back, Apache-2.0 on cli/ and sdk/ so integrators carry no obligation, Elastic License 2.0 on ee/. Inbound=outbound with a DCO and deliberately no CLA."
tags: [licensing, ee, community]
status: stable
adr: "0027"
adr_status: "Accepted"
date: 2026-08-22
generated: { by: human:jhgaylor, at: 2026-08-22T12:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-22T12:00:00-04:00 }
---

# 0027 — AGPL-3.0 for the server, Apache-2.0 for the clients, Elastic 2.0 for `ee/`

**Status:** Accepted. Everything described here is built in the PR that adds
this ADR. `LICENSE` is the AGPL text, `cli/LICENSE` and
`sdk/typescript/LICENSE` are Apache-2.0, `ee/LICENSE` is the Elastic License
2.0, and `NOTICE` and `CONTRIBUTING.md` exist. This ADR supersedes the closing
line of 0010's addendum, which reserved the license question ("everything
remains MIT until an explicit license decision says otherwise"). This is that
decision.

## Context

Fountain was MIT-licensed from the first public commit (2026-05-10) through
v0.12.0 (2026-08-17), and is about to launch commercially (0026 builds the
paid tiers). MIT permits a funded competitor to take the work, host it, improve
it, and return nothing. The improvements are the part that matters: not the
revenue, which competition is entitled to pursue, but the fact that everyone
else running Fountain gets no benefit from a well-resourced fork's work.

Three facts made this the cheapest possible moment to act, and all three
expire:

- **Two stars, zero forks, and no npm publish.** No downstream user is relying
  on the MIT grant. A relicense a year from now would be the rug-pull the
  community reads as betrayal; today it is a choice made before release.
- **The `ee/` boundary already exists.** 0010 moved billing and growth mail
  behind a directory line *specifically* to preserve this option, and its
  addendum narrowed the scope so a community instance never needs `ee/` for
  anything real.
- **The copyright is entirely one holder.** No third-party contribution has
  ever been merged. `lex00` filed six issues in 2026-07 and pushed work to
  `origin/issue-*` branches, but opened no pull request, none of those commits
  is an ancestor of `main`, and `git blame` finds zero surviving lines. The
  features landed through separate commits the following day. MIT grants
  sublicensing rights in any case, so no contributor's consent was required.

## Decision

**Three licenses, one per directory, chosen by what the code is for.**

| Directory | License | Reason |
|---|---|---|
| `apps/fountain`, `config`, `priv` | AGPL-3.0-or-later | Section 13 is the whole point: run a modified server as a network service, owe your users the source |
| `ee/` | Elastic License 2.0 | Source-available, free to self-host, no copyleft, no competing hosted service |
| `cli/`, `sdk/typescript` | Apache-2.0 | An integrator must never inherit an obligation from calling the API |

The first-party single-page apps (`fountain-conversations`, `fountain-team`)
are Apache-2.0 in their own repositories, for the same reason as the SDK.

**Inbound=outbound, with a DCO and no CLA.** A contribution is licensed under
whatever governs the directory it touches. There is no copyright assignment.

### Why AGPL and not FSL or BUSL

The grievance is that improvements do not come back, not that a competitor
exists. AGPL answers exactly that and nothing more: a competitor may host
Fountain commercially, in direct competition with the hosted product, provided
they do it in the open. A non-compete source-available license (FSL, BUSL,
Elastic on the core) would answer a different grievance, forfeit the
OSI-approved "open source" claim at the moment of launch, and cost adoption
the project cannot yet afford to lose.

### Why the clients stay permissive

An AGPL SDK is poison. It puts a copyleft obligation on every proprietary
application that links it, which is precisely the integration Fountain wants.
The split follows the shape the ecosystem already uses (an AGPL Grafana with
Apache plugin SDKs, an SSPL MongoDB with Apache drivers). The API boundary is
the license boundary.

### Why `ee/` is Elastic License 2.0 and not AGPL

Two reasons, and the second is the load-bearing one.

The first is the obvious one: `ee/` is the commercial surface, and ELv2's
first limitation forbids offering it to third parties as a hosted service.

The second is that **AGPL binds Fountain's maintainer too**. With AGPL
everywhere, every hosted-only feature ever written would have to be published.
`ee/` is the lane where that is not true. That is what 0010 was actually
preserving, and it is worth more than the billing code itself, which is 4,550
lines of Stripe integration nobody needs to steal.

ELv2 rather than a bespoke license because the single-image decision
(0010's addendum) makes the grant load-bearing. `ee/` compiles into the same
`:fountain` OTP app via `elixirc_paths`, core calls it directly, there is no
ee-less build, and `billing_live.ex` still hosts the account export and
deletion UI. Every self-hoster therefore *runs* `ee/` code. A license without
a free use grant would make all of them infringers. ELv2 grants use and
modification at no cost and restricts only redistribution as a service, which
is the shape this actually needs. It is also drafted by lawyers, which a
bespoke file would not be.

### Why no CLA

A CLA would let the maintainer sell commercial exceptions to a company that
wants Fountain without AGPL obligations, converting the feared competitor into
a customer. It is declined because the asymmetry ("you grant me rights I do
not grant you") is the standard reason contributors walk away from a young
project, and Fountain needs contributors more than it needs that lever.

The consequence is accepted openly and written into `CONTRIBUTING.md`: with no
CLA, the maintainer cannot relicense a contributor's work either. The AGPL
guarantee binds the maintainer exactly as hard as it binds anyone else.

## Consequences

- **Releases through v0.12.0 stay MIT, irrevocably.** Anyone who obtained them
  keeps that grant. This is unavoidable and is why the timing mattered.
- **Some enterprises cannot run Fountain.** AGPL is banned by policy at Google
  and at a meaningful number of other companies. Those self-hosters are lost,
  knowingly.
- **A hosted-only feature must live in `ee/` or be published.** This is a real
  roadmap constraint, and it is the first question to ask of any feature meant
  to be exclusive to the hosted product.
- **Adding a CLA later requires asking every contributor.** Reversing the
  no-CLA decision gets harder with each merged pull request.
- **The dual-licensing option is intact today and expires on the first merged
  outside pull request.** Sole copyright means commercial exceptions could
  still be sold without asking anyone. Declining a CLA spends that option
  gradually rather than having already lost it, which is the honest way to
  state the cost of the previous section.
- **`NOTICE` records the MIT terms** the v0.12.0 and earlier releases were
  distributed under. That record is for the people holding those releases, not
  a condition Fountain must satisfy, since no third-party code is in the tree.
- **Per-file license headers were not added.** A root LICENSE, `NOTICE` and
  the README table are the record. Headers across 56,000 lines are noise, and
  the AGPL does not require them.
- **Dependencies were checked and none conflict.** The set is MIT, Apache,
  BSD and ISC, plus `open_api_spex` (MPL-2.0, file-level copyleft, compatible,
  unmodified) and `muzak` (CC-BY-NC-ND, `only: :test`, absent from the release
  image).

## Not done yet (deliberately)

- **A lawyer has not reviewed this.** The structure is conventional and the
  license texts are verbatim from their canonical sources, so nothing here is
  novel drafting. An hour of review before the commercial launch is still
  cheap insurance, and the `ee/` grant is the clause to review first.
- **Trademark policy.** The licenses cover copyright. Nothing yet governs use
  of the Fountain name by a fork, which is the other half of how projects
  defend themselves.
- **The core-only build and the dependency-inversion seams** from 0010 remain
  unbuilt. They are not required by this decision, because ELv2 grants
  self-hosters the right to run `ee/`.
