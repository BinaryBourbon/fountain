---
type: ADR
title: "A sandbox's files and git diff over the API, and no exec"
description: "Apps that watch an agent work get three read-only requests on a sandbox — a directory listing, one file, git diff — full-scope only, confined to the home and the runtime workspace, redacted like the transcript, never waking a parked sandbox. Built over the seam's existing exec, so no adapter or runner change. A raw exec endpoint is refused: it would be a second I/O path beside ACP, unmetered, unredacted and, on a runner, a shell on the user's machine behind a bearer token."
tags: [api, sandbox, security, apps]
status: stable
adr: "0039"
adr_status: "Accepted"
date: 2026-09-02
generated: { by: claude-fable/5.1, at: 2026-09-02T02:00:00-04:00 }
verified: { by: claude-fable/5.1, at: 2026-09-02T02:00:00-04:00 }
---

# 0039 — A sandbox's files and git diff over the API, and no exec

**Status:** Accepted, 2026-09-02. Built in the same PR: `Fountain.SandboxFiles`,
`FountainWeb.SandboxFilesController`, the three routes, the SDK's
`sandboxFiles` / `sandboxFile` / `sandboxDiff` (1.15.0). Nothing described
here is unbuilt.

## Context

Two of the apps built on the API (ADR 0003, [0021](0021-oauth-for-first-party-apps.md))
asked for "sandbox exec and file APIs". Both are apps that watch an agent
work, and the transcript is not always enough: the app wants to show the
file the agent just wrote, the tree it is working in, and what changed in
the repository since the turn began.

What the codebase already says about that request:

- **The seam has exec and no read.** `Managoat.Sandbox` ([0018](0018-sandbox-provider-abstraction.md),
  [0037](0037-component-libraries.md)) requires `exec/4`, `spawn/4` and
  `write_file/4` of every adapter and has no `read_file`, `list_dir` or
  download callback. Fountain reads a file out of a sandbox by `exec`ing
  `cat` — the E2B adapter's only read primitive is internal, to poll an
  exit-code file. Exec is therefore cheap to expose, and a file API is the
  one that would need new seam work across four adapters and the runner
  daemon's protocol.
- **Nothing under `fountain_web/` touches a sandbox.** Every side effect
  goes through `Fountain.Conversations` and its server, which is what makes
  audit ([0013](0013-audit-trail.md)) and redaction hold by construction.
- **There are two API key scopes, `full` and `sprite`,** and everything
  under the plain `:api` pipeline is reachable with a `sprite` key — the
  token a conversation hands its own sandbox. That is deliberate (the
  bundled `fountain` skill fans out sub-agents) and it is the fact that
  decides the shape of anything that reads a disk.
- **A sandbox is keyed by `{agent, environment, vault}`** ([0023](0023-persistent-agent-sandbox.md))
  precisely so that a compromised home never holds two identities'
  credentials. `.env` on that disk is the identity's secrets in plaintext;
  the callback token and the broker session token are process-only and
  never reach it (`Fountain.Conversations.Identity`).
- **Redaction is applied in exactly one place,** `Conversations.log!/1`.
  Raw exec output and raw file bytes never pass it.
- **Credits burn on turns** ([0031](0031-credits-are-the-product.md)).
  `Billing.check_spend/1` gates conversation creation, attach, wake and
  every turn, and nothing below that. An exec that opens no turn burns
  nothing while costing provider time.
- **The broker's protection is network-shaped** ([0019](0019-egress-credential-brokerage.md)):
  a placeholder is worthless off the box because egress is pinned to the
  proxy. A read channel out of the box is one the proxy does not sit in
  front of.
- **A runner sandbox is a directory on the user's own machine** in trusted
  mode with no isolation ([0022](0022-self-hosted-runner-provider.md)).

## Decision

1. **Three read-only requests, on the sandbox, not the conversation.**
   `GET /api/sandboxes/:id/files` (a directory), `/file` (one file's
   bytes) and `/diff` (`git diff`, with `staged` and `ref`). They are
   addressed by sandbox because on a persistent home the disk is shared by
   every conversation of the identity, and a conversation-scoped read
   would mislead the app about what it is looking at.

2. **No exec.** The three operations are fixed scripts in
   `Fountain.SandboxFiles`; the caller chooses a path and a few flags,
   never a command. A raw exec endpoint would be a second I/O path beside
   ACP ([0014](0014-agent-client-protocol.md)) that routes around the
   governance proxy ([0016](0016-governance-as-an-acp-proxy.md)); it would
   be unmetered under 0031; its output would never pass redaction; on a
   shared home it could read every other conversation's process
   environment, which is exactly what `Identity` keeps out of `.env`; and
   on a runner it would turn a leaked API key into a shell on the user's
   laptop. If a further purpose-shaped read is wanted (`git status`, a
   test run's report), it gets the same treatment: a fixed script, a
   named endpoint, this ADR amended.

3. **Full scope only.** The routes sit behind `require_full_scope`, with
   the egress log (#1152). A `sprite` key must never read another sandbox
   of the tenant, whose disk was built from a different vault — that is
   the cross-identity leak 0023's key exists to prevent, and it would
   otherwise be one HTTP call from inside any sandbox.

4. **Confined to the home and the workspace.** A path resolves against the
   agent's working directory (`Managoat.Runtimes.ACP.cwd/1`) and must be
   `/home/sprite`, that directory, or inside one of them
   (`422 path_outside_sandbox`). On a hosted provider this costs the
   caller `/etc`, which "watching an agent" does not need; on a runner it
   is what keeps the API off the rest of the user's filesystem.

5. **Redacted like the transcript.** Every byte that leaves — file
   content, diff text, a failing command's output — passes the same
   replacement `Conversations.log!/1` applies: the values of the
   identity's environment and vault (decrypted for the request, eight
   bytes or longer) plus whatever a live `ConversationServer` registered,
   which is how the inference credential and the callback token are
   covered. Without this, the `.env` on that disk would be readable back
   through a third-party app holding the user's key.

6. **Never a wake.** Only a `ready` sandbox answers; a `suspended` one is
   `409 sandbox_not_ready` and stays parked. A read that resumed a sandbox
   would cost provider time outside any turn, with nothing in 0031 to
   charge it to; a prompt is the door that wakes, and it is gated.

7. **Over `exec`, not a new callback.** The scripts run through
   `Managoat.Sandbox.exec/4`, which every adapter already implements, with
   the path as a positional parameter (`bash -c SCRIPT NAME ARGS…`) so a
   filename is data whatever it contains, and paths crossing
   `Managoat.Sandbox.host_path/2` so the runner's `/home/sprite` mapping
   holds. Bytes travel base64-encoded from inside the sandbox so they
   survive whichever transport an adapter streams stdout over. Adding a
   `read_file` callback would have meant four adapters, the runner
   daemon's protocol, and new public surface on a library heading for hex
   (0037), for a read the existing primitive already serves.

8. **Bounded.** A file read returns at most `max_bytes` (default 256 KiB,
   cap 4 MiB) and reports `size` and `truncated`; a listing returns at most
   2,000 entries; a diff is capped the same way; every script has a
   30-second timeout. Reads are not audited (0013 audits mutations) and
   not gated by `check_spend/1` (they spend nothing: the sandbox is
   already running and is not woken).

## Consequences

- The two apps get what they need — a file tree, a file, a diff — through
  three SDK calls beside `sandboxes()`, and nothing they did not ask for.
- The one new attack surface is a read channel out of the sandbox. It is
  bounded by full scope, the path confinement and redaction, and it is
  the user's own disk. What it does not cover: a secret an agent wrote to
  disk *itself* is not in the redaction set (the same limit the transcript
  has), and a brokered API's response, fetched through the proxy and
  written to a file, is readable through this API by the same user who
  could have asked the agent to print it.
- Every provider is covered on the day it ships, including the runner,
  without touching `managoat_sandbox` or `managoat_runner`.
- The `api_spec_test` route walk and the SDK freshness check mean the
  routes could not land undocumented; the SDK's resource and the Swift
  client's vendored spec are hand-written follow-ups by design.

## Alternatives considered

- **A raw `POST /api/sandboxes/:id/exec`.** Refused, for the five reasons
  in decision 2. The honest version of "we need exec" is a list of the
  commands the app would run, and that list is a set of named endpoints.
- **`read_file` / `list_dir` callbacks on the seam.** The cleaner
  architecture, and the right move if a provider ever offers a file API
  that is materially cheaper than a process. Deferred: it is four adapters
  and a daemon protocol change for no behaviour the scripts do not
  already deliver.
- **Conversation-scoped routes** (`/api/conversations/:id/files`).
  Rejected because the disk is the sandbox's, not the conversation's
  (0023), and because a conversation's own `sprite` key could then reach
  the route by the plain `:api` pipeline unless it, too, were full-scope —
  at which point the conversation adds nothing but a misleading name.
- **Allowing any absolute path.** Rejected for the runner's sake, and
  because nothing an app watching an agent needs lives outside the home
  and the workspace.
- **Waking a parked sandbox on read.** Rejected: unmetered provider time,
  and a surprise to a user whose parked home starts costing money because
  a dashboard polled it.
