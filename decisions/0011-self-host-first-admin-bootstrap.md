---
type: ADR
title: "Self-host first login without release tasks"
description: "A self-hosted instance's first login needs no release tasks: EMAIL_DELIVERY=none implies auto-verification and FIRST_USER_ADMIN=true promotes the first verified account."
tags: [self-host, auth]
status: stable
adr: "0011"
adr_status: "Accepted"
date: 2026-08-04
generated: { by: human:jhgaylor, at: 2026-08-04T21:35:27-04:00 }
---

# 0011 — Self-host first login without release tasks

**Status:** Accepted

## Context

A self-hosted instance's first-login path required two `bin/fountain_server
eval` release tasks before the instance was usable: `verify_email/1` (because
`EMAIL_DELIVERY=none` means the verification link never arrives, while login
still hard-requires `email_verified_at`) and `promote_admin/1` (the only
first-admin path). Deploy tooling had to grow machinery — pods lifted from the
live Deployment spec — to run per-account eval commands, and the getting-started
docs led with it. Both steps guard nothing on the instances that need them:
email verification proves an address can receive mail, which is meaningless on
an instance configured to send none; and the first admin on a single-operator
instance is always the person who just deployed it.

The constraint making this non-obvious: the same codebase runs the hosted
multi-tenant deployment, where auto-verification would weaken signup and
first-user-admin would hand the instance to whoever registers first.

## Decision

Two independent switches, both inert on the hosted deployment:

1. **`EMAIL_DELIVERY=none` implies auto-verification.** `runtime.exs` sets
   `:email_enabled false` in that branch (default `true`); registration then
   stamps `email_verified_at` at creation and the registration responses say
   "you can sign in" instead of "check your email". No new variable — the
   existing opt-out already declares that delivery is impossible.

2. **`FIRST_USER_ADMIN=true` promotes the first verified account.** Opt-in,
   default off. The grant fires on *verification*, not registration, so it
   always lands on a login-capable account and stays orthogonal to how the
   instance handles email. It is hooked into `Accounts.verify_email/1` (the
   emailed link, the release task, and the auto-verify path all converge
   there) and into the OAuth new-user path (which stamps verification at
   insert). A Postgres advisory xact lock serializes concurrent first
   verifications so exactly one can observe "no admin exists". The promotion
   is audit-recorded as `admin.role.granted` with a nil actor and
   `via: "first_user_admin"`, and is best-effort on the same terms as audit
   logging — a bootstrap failure logs rather than failing the verification.

`Fountain.Release.verify_email/1` and `promote_admin/1` remain as escape
hatches (broken mail provider, lock-out recovery, instances that keep the
switch off), but stop being part of the documented first-login path.

## Consequences

- A self-hoster sets `FIRST_USER_ADMIN=true` (and typically
  `EMAIL_DELIVERY=none`), registers, and has a verified admin account — the
  deploy tooling's `verify-email` / `promote-admin` recipes and the
  first-login doc's failure-mode tables become unnecessary.
- `docker-compose.yml` defaults the switch **on** (the app default stays
  off): compose is the single-operator quickstart, and its posture already
  optimizes for first run (`EMAIL_DELIVERY=none` by default). Other deploy
  methods opt in explicitly.
- An internet-reachable instance with `FIRST_USER_ADMIN=true` and no admin
  yet gives admin to whoever verifies first. Accepted: the switch is opt-in,
  operators register immediately after standing up an instance, and the
  declared-email alternative below remains buildable if this proves wrong.
- With `EMAIL_DELIVERY=none`, a forgotten password is unrecoverable in-app
  (no reset email). This was already true; the boot-time notice now says it
  plainly instead of pointing at `verify_email/1`.
- Accounts created under `EMAIL_DELIVERY=none` keep `email_verified_at` if
  the operator later configures real mail — verification timestamps no longer
  prove an address ever received anything on instances that have used this
  mode.

## Alternatives considered

- **`BOOTSTRAP_ADMIN_EMAIL=<addr>`** (Grafana/Keycloak pattern) — no
  first-to-register window, but reintroduces coordination between config and
  signup: the deploy has to know the admin's address before the admin exists,
  and a typo strands the instance adminless again.
- **Setup wizard at `/setup` while no admin exists** — best UX, most surface:
  a new unauthenticated route, its own rate-limit/abuse story, and layout
  work, for a flow that runs once per instance.
- **First *registered* (not verified) user is admin** — simpler, but grants
  admin to an account that may never be able to log in, and couples the two
  switches: correct only when auto-verification is also on.
- **Keep release tasks, improve tooling** — the status quo; leaves every
  deploy method (compose, k8s, bare release) to reinvent eval-pod machinery
  the app can obsolete in two branches.
