---
type: ADR
title: "Users link a ChatGPT subscription and Fountain manages the grant"
description: "Proposed, not built: tenant-owned ChatGPT grants reuse the Codex broker path, with tenant encryption, coordinated refresh, explicit credential selection, and no automatic paid fallback."
tags: [inference, codex, oauth, security, billing]
status: draft
adr: "0052"
adr_status: "Proposed"
date: 2026-09-11
generated: { by: "process:codex", at: 2026-09-11T20:37:30-04:00 }
stale_after: 2026-10-11
---

# 0052 — Users link a ChatGPT subscription and Fountain manages the grant

**Status:** Proposed; none of the user-level behavior below is built.
The existing implementation described below was checked against `main` at
`c5b0e86c` on 2026-09-11.

Extends [0047](0047-codex-platform-chatgpt-account.md),
[0008](0008-byo-inference-credentials.md), and
[0019](0019-egress-credential-brokerage.md). Preserves the distinction between
own and platform inference in [0038](0038-onboarding-first-reply.md).
The proposed credential policy prefers the user's subscription, offers an
explicit API-key choice, and never silently switches to paid inference.

## Context

The admin can already link a ChatGPT account by device code or import and
Fountain owns refresh. Users should have the same managed lifecycle for
their own subscription, shared across their own Codex agents. Linking an
inference account does not change the user's Fountain login identity.

The existing implementation provides most of the transport:

- `platform_chatgpt_account` already has an owner FK with deletion cascade,
  a unique non-null `user_id`, and a separate singleton platform row.
- `PlatformChatGPT.OAuth`, `Tokens`, and `Device` implement the exchange;
  `CodexChatGPT`, `CodexTransport`, and the broker implement sandbox access.
- `PlatformChatGPT` encrypts every token with the platform key and reads
  only `user_id IS NULL`. `CodexChatGPT.prepare_sandbox/3` and
  `Egress.refresh_platform_chatgpt/2` fetch that same global account.
- `PlatformChatGPT.Refresher` serializes on one node. Across nodes, its
  compare-and-swap prevents stale writes but does not prevent duplicate
  refresh requests reaching OpenAI. Terminal-error writes also need fencing.
- Codex writes a shared `$CODEX_HOME/auth.json`. Adding a second account
  source requires explicit handling of concurrent peers and account changes.

This is more than exposing the admin button: a user token must never be
paired with platform identity metadata, refreshed from the wrong row, or
classified as platform-paid inference.

Official [authentication documentation](https://learn.chatgpt.com/docs/auth)
distinguishes ChatGPT subscription access from usage-based API access.
The [app-server documentation](https://learn.chatgpt.com/docs/app-server)
describes an experimental externally managed ChatGPT-token mode, including
a host refresh callback. These establish a relevant integration mechanism;
they do not establish that Fountain's exact hosted device-code/broker path
is a stable public OAuth integration. Verify the pinned client and exchange
before rollout. ADR 0047's idle-lifetime measurement remains outstanding in
the inspected baseline; do not present its timing assumptions as guarantees.

## Decision

Let authenticated users connect one ChatGPT account for their own Codex
workloads. Fountain stores and rotates the grant; sandboxes receive only a
broker placeholder and the minimum matching account metadata. Reuse the
existing grant table and transport through a shared, explicitly scoped
context. User grants are BYO inference. The first version supports Codex on
broker-enabled backends; general OpenAI API calls and other runtimes still
require their existing credentials.

### 1. Explicit ownership and encryption

Introduce `Fountain.ChatGPTAccounts` with separate user and platform entry
points; retain `PlatformChatGPT` as an admin compatibility wrapper. User
methods require authenticated `user_id` and scope their first query by it.
Never interpret an absent user ID as a request for the platform account.

Reuse `platform_chatgpt_account` despite its historical name. Preserve the
two uniqueness constraints and the platform row. Encrypt user access and
refresh tokens with that user's DEK; retain platform encryption for the
null-owner row. Choose encryption from immutable ownership, never by trying
both keys. There is no transfer of a grant between users or scopes.

Add a grant generation distinct from token rotation: reconnect or account
replacement changes generation; normal refresh does not. Use a separate
version for conditional lifecycle writes. Validate existing non-null rows
before migration; the baseline has no writer for them, so unexpected rows
must not be silently reinterpreted under a different encryption key.

Status returns only connection state, account display metadata, expiry,
last successful renewal, and a sanitized failure reason. Tokens are never
returned by account APIs, exports, audit events, logs, or LiveView assigns.
Account deletion cancels pending attempts and invalidates broker access as
well as cascading the grant and tenant key. Export only non-secret metadata,
consistent with [0009](0009-account-deletion-and-export.md).

### 2. Device-code linking in account settings and the API

Add a **ChatGPT subscription** card to `/account/inference-credentials`:
Connect, account/plan display, Connecting, Connected, Reconnect required,
and Disconnect. Explain that it serves Codex and Fountain manages renewal.
Show the verification URL and user code from the existing exchange. Give
actionable instructions if the account has device login disabled.

Provide the same operations beneath the existing full-scope
`/api/account` boundary, using a dedicated `chatgpt` resource: status,
create/read/cancel a connection attempt, disconnect, and credential preference.
Do not expose a public "get access token" or refresh endpoint. A sandbox's
conversation-scoped token cannot start or change a link. Browser mutations
use the existing authenticated session and CSRF protections.

An attempt is short-lived, owner-bound, and single-use, with an opaque ID.
Store any exchange secrets encrypted; jobs carry IDs, never tokens. Limit
pending attempts and honor upstream polling intervals, expiry, and backoff.
Page reload can recover status. Completion rechecks owner eligibility,
cancellation, expiry, and grant generation before storing anything. A late
completion cannot undo Disconnect or replace a newer connection. Reconnect
keeps the old usable grant until the new exchange commits successfully.

Device code is the first-version user flow. Auth-file import and static
workspace tokens remain admin capabilities initially; adding their user
surfaces is separate follow-up work. No generic OAuth-provider registration
or new Fountain login method is part of this change.

### 3. One refresh owner per grant across the deployment

Extract shared refresh mechanics and key local request coalescing by grant
ID, rather than putting all users behind one process queue. Coordinate the
upstream call across nodes with a per-grant PostgreSQL advisory lock. Try
the lock without waiting; losing callers release their database checkout
and retry with bounded backoff or read the winner's committed result.
Re-read state and expiry after acquiring the lock. Bound refresh-worker
concurrency and HTTP timeouts so lock holders cannot exhaust the DB pool.

Fence success, terminal failure, reconnect, and disconnect writes by grant
ID, generation, version, and active state. Persist the rotated token set
before serving it. A stale failure cannot revoke a newly connected grant.
Do not rely on the observed tolerance for refresh-token reuse in ADR 0047.
An upstream rotation followed by a crash before commit is still an
unavoidable external-system failure window; recovery must handle reconnect
without claiming exactly-once refresh or retrying indefinitely.

Refresh before expiry and before a turn, sharing the configurable margin
with the platform implementation. Fan out keepalive work in bounded batches
over active refreshable grants, with jitter and one job per grant. Keep the
existing timing provisional until the pending lifetime measurement is
recorded. Transient failures retain the grant and retry with backoff;
terminal rejection requires reconnect. No keepalive after disconnect.

### 4. Select and carry the account source explicitly

Extend selection to return source identity alongside `:own` or `:platform`:
credential kind, owner scope, grant ID, generation, and matching account
metadata. Carry the source through provision, resume, reattach, and refresh.
Never infer ownership by comparing access-token strings. Token and account
metadata must come from the same scoped read/version.

Recommended default for eligible Codex runs:

| User configuration | Selected source |
|---|---|
| A linked subscription is selected | User ChatGPT grant; `:own` |
| User explicitly selects their API key, or only has that key | User API key; `:own` |
| No user OpenAI credential or subscription selection | Existing platform ChatGPT, then platform API-key policy |
| Selected subscription is revoked, expired, unavailable, or quota-limited | Actionable error; no automatic API/platform switch |

Connecting offers subscription use as the default and makes any change
from an existing API key visible. A user-level preference handles accounts
holding both; no per-agent preference in the first version. Disconnecting
the selected grant retains a reconnect-required preference until the user
explicitly chooses another source. This prevents the next run silently
incurring paid inference. Existing accounts with no user grant keep their
current behavior.

Eligibility checks must include runtime and broker capability. Do not add
the subscription as a universal `openai` credential: OpenCode, image/avatar
generation, and other direct API consumers must still require API keys.
Read-only status and onboarding checks do not decrypt or refresh tokens.
Environment/vault API-key overrides must resolve into the same explicit
source decision; do not allow an env key to silently override a selected
subscription later during provisioning.

### 5. Pin sandbox identity and invalidate access

Use the selected grant to build Codex's placeholder `auth.json`; eliminate
the global `PlatformChatGPT.sandbox_auth/0` lookup from the user path.
Refresh broker rules from that exact grant. Preserve the existing
ChatGPT HTTP transport and ACP authentication behavior.

Give peers with different credential sources/generations separate
`CODEX_HOME` auth locations so an existing platform conversation and a new
user conversation cannot overwrite one another's account file in a shared
sandbox. Preserve the runtime configuration, skills, and session-resume
behavior when changing this path. Verify the pinned runtime/ACP library's
support; include a library change and release if its fixed layout prevents it.

Pin source/generation for a running peer. Normal token rotation updates
the broker without rewriting its auth file. Source changes take effect on
new peers; reconnecting to a different account invalidates old-generation
peers and requires reauthentication before another turn. Do not swap only
the bearer beneath an old account ID.

Disconnect invalidates all broker sessions using that grant, removes cached
credentials, and fences refresh/link completion across nodes. Do not report
completion while known sessions can still start authenticated requests;
retry invalidation failures and expose pending status. Already-forwarded
requests cannot be recalled. Where upstream revocation is supported, attempt
it; local unlink does not promise that the upstream token itself was revoked.

The first version retains ADR 0047's limitation for a turn that outlives its
access token: report the upstream failure without automatic prompt replay
or paid fallback. The app-server refresh callback is a possible follow-up,
not assumed to work through the present ACP bridge.

### 6. Billing and audit follow the owner

A user grant produces `inference_origin: :own`: no platform inference debit
or platform inference daily-ceiling consumption. Normal sandbox/runtime
charges and applicable spend/admission checks still apply. Preserve source
identity in turn accounting so reconnect or restart cannot relabel usage.
Subscription limits remain the user's provider limits; do not imply unlimited
inference or availability of every API model from a reported plan label.

Use tenant audit events for connected, disconnected, reconnect-required,
and preference changes, with an explicit user/system actor and safe metadata.
Keep platform events in the admin audit trail. Routine refreshes use bounded
operational metrics, without tokens, raw provider responses, or account
email labels.

## Implementation sequence and acceptance

1. **Shared context and lifecycle.** Add owner-scoped reads/writes,
   encryption dispatch, generation/version fencing, and coordinated refresh.
   Keep the existing admin UI working through its wrapper. Validate tenant
   isolation, wrong-DEK failure, two-node refresh contention, terminal-error
   races, disconnect during refresh, and crash/timeout recovery.
2. **Selection and Codex transport.** Carry source identity through all
   lifecycle paths; isolate auth locations and update broker rules by source.
   Test two users plus the platform concurrently, API/subscription peers in
   one sandbox, refresh between prompts, restart/reattach, account replacement,
   unbrokered backends, env overrides, and non-Codex/direct-API consumers.
3. **Account API and console.** Add attempts, status, preference, reconnect,
   and disconnect to the shared context and both surfaces. Add OpenAPI/SDK
   contracts as appropriate. Test ownership and full-scope authorization,
   cancellation/expiry/replay, late completion, redaction, and page reload.
4. **Accounting and rollout.** Test BYO versus platform debits and ceilings,
   deletion/export, keepalive scheduling, and broker invalidation on every
   serving node. Exercise a real link, Codex turn, forced refresh between
   turns, restart, and disconnect in a controlled environment. Record the
   pinned versions and evidence; then enable the user surface gradually.

UI availability is gated until the complete lifecycle and selection path
pass these checks. Disabling new linking must not orphan existing grants:
status, refresh, reconnect recovery, and disconnect remain operable.

## Consequences

Users can use their own subscription without moving rotating credentials
between sandboxes. The server becomes responsible for lifecycle and
revocation across nodes. One user grant serves only that tenant; it is not
inherited by another user, an owned principal, or a platform fallback pool.

The initial scope is deliberately one linked account per user and Codex
only. Provider account/workspace switching is reconnect, not a multi-account
router. The extra coordination and source tracking are required to make
token custody safe and billing predictable, even though the exchange and
broker already exist.

## Alternatives considered

- **Expose the admin flow with a user ID parameter only.** Leaves global
  reads, encryption, billing, and shared auth-file assumptions unresolved.
- **Add a static token column to inference credentials.** Cannot express
  rotating refresh credentials, connection attempts, or reconnect state.
- **Duplicate the admin implementation into a user module/table.** Splits
  protocol fixes and lifecycle behavior; the existing schema already has
  tenant slots.
- **Put refresh tokens in Codex sandboxes.** Violates central custody and
  permits independent refresh owners for the same grant.
- **Use generic Connections as the entire feature.** Its OAuth helpers are
  useful precedent, but Codex device exchange, auth-file preparation,
  inference selection, and billing need an inference-specific context.
- **Silently fall back to an API key or platform grant.** Changes whose
  quota or money is consumed when the user selected their subscription.
