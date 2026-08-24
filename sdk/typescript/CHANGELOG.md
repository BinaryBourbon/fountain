# Changelog

Notable changes to `@agentshit/fountain-sdk`. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

The SDK versions independently of the Fountain server. It talks to the REST
API, which is additive, so a given SDK release keeps working against later
server releases.

---

## [0.1.12] — 2026-08-24

### Changed

- `PATCH /api/agents/{id}`, `DELETE /api/environments/{id}` and
  `DELETE /api/vaults/{id}` now carry a `409` response in the generated
  types. Each of those requests can move a persistent home's identity key,
  so the server retires the machine and refuses the request while a
  conversation on it runs a turn (#1084). `FountainError` already maps 409
  to `conflict`; the error body's `error` is `sandbox_mid_turn`.

---

## [0.1.11] — 2026-08-24

### Added

- `Sandbox.checkpoint` — `{ id, at }` or `null`: the checkpoint Fountain
  took of a persistent home the last time it parked, generated from the
  server's spec. It is scoped to that machine (ADR 0023, #1073).

## [0.1.10] — 2026-08-24

### Added

- `Turn.origin` — `"user"` for a prompt somebody sent, `"autonomous"` for a
  turn the server opened for a background cycle the agent ran after its
  prompt was answered (part 2 of BinaryBourbon/fountain#817). Generated from
  the server's spec; optional in the type because rows from before the field
  read as `user`.

## [0.1.9] — 2026-08-24

### Changed

- Generated types follow the server's Buzz identity schema: `sandbox_mode`
  on `POST /api/buzz/agents` and in the identity JSON (server #1070). No
  client method changed.

## [0.1.8] — 2026-08-24

### Added

- `resetSandbox(id)` — `DELETE /api/sandboxes/:id`: destroy a persistent
  sandbox (the agent's home) so the next launch on the same agent,
  environment and vault builds a clean machine; the conversations on it are
  kept. `sandbox_not_resettable` for an ephemeral or already-gone sandbox,
  `sandbox_mid_turn` while a conversation on it runs a turn (#1071).

## [0.1.7] — 2026-08-24

### Added

- `run({ sandboxMode })` — `"ephemeral"` or `"persistent"`, replacing the
  agent's default for that conversation. A persistent conversation lands on
  the agent's own machine, which Fountain makes on the first such launch;
  while that first launch is still building it, a second one gets
  `provisioning` (retryable). Agents carry `sandbox_mode` and sandboxes carry
  `mode`, both generated from the server's spec (ADR 0023).

## [0.1.6] — 2026-08-24

### Added

- `run({ sandbox })` attaches the new conversation to a sandbox you already
  have, by id, instead of provisioning one — several conversations then run
  on one disk at once (ADR 0023). `fountain.sandboxes()` and
  `fountain.sandbox(id)` list your machines with the conversations on each
  and which is mid-turn; `SandboxRecord` is their type. `Sandbox` records
  now carry `agent_id`, `environment_id` and `vault_id`.
- Error codes: `sandbox_not_found`, `sandbox_not_attachable`,
  `sandbox_identity_mismatch`, `sandbox_runtime_mismatch`, and
  `sandbox_at_capacity` (retryable — a one-at-a-time runtime's machine is
  busy with another conversation's turn).

## [0.1.5] — 2026-08-24

### Fixed

- No `User-Agent` header when running in a browser. Firefox lets a page set
  one, which turned every call into a CORS preflight asking for `user-agent`,
  and a Fountain whose allow-list did not name it refused the request ("CORS
  Missing Allow Header") — the first thing a signed-in single-page app saw.
  Node and other non-browser runtimes still send `fountain-sdk-js/<version>`.

## [0.1.4] — 2026-08-24

### Added

- `expires_at` on vault secrets, generated from the server's OpenAPI spec.
  `VaultSecretRequest` accepts it (ISO 8601 date-time, or `null` to clear a
  stored expiry) and `VaultSecret` returns it; a request that omits the field
  leaves the stored expiry alone. It is advisory metadata: the server emails
  the owner ahead of the date and enforces nothing on it, so an expired secret
  is still injected as-is. Values stay write-only.

## [0.1.3] — 2026-08-23

### Added

- Turn-hour types, generated from the server's OpenAPI spec (fountain ADR 0026,
  amended). `GET /api/account/billing` now reports what a plan includes and
  what the account has spent against it.

  - `plan.included_turn_hours` — turn hours the tier carries per billing
    period.
  - `usage.turn_hours`, `usage.turn_hours_included`,
    `usage.turn_hours_remaining`.
  - `current_period_start` beside the existing `current_period_end`.
  - `period.source` — `"subscription"` or `"calendar_month"`.

  A **turn hour is not a sandbox hour.** It counts time with a prompt in
  flight, so an agent left running with nobody talking to it spends
  `usage.sandbox_minutes` and none of the allowance. Do not present the two as
  the same unit.

  Read `period.source` before showing an allowance. `"calendar_month"` means
  the server has no invoiced period for that account (comped, self-hosted, or
  no subscription webhook yet), so the numbers do not line up with an invoice
  and a UI that implies they do will be wrong for exactly those accounts.

  Nothing is enforced against these numbers today — no request fails for
  exceeding the included hours.

All fields are optional and additive; nothing existing changed shape.

## [0.1.2] — 2026-08-23

### Added

- Subscription plan types, generated from the server's OpenAPI spec
  (fountain ADR 0026). `GET /api/account/billing` now returns a `plan` object —
  `slug`, `name`, `monthly_cents`, `concurrent_sandboxes`, `sandbox_limit` and
  `team_contacts` — and the checkout endpoint accepts a `plan` query parameter
  naming the tier to buy.

  Read `plan.sandbox_limit`, not `plan.concurrent_sandboxes`, when showing a
  customer how many agents they may run at once. The first is what the server
  actually enforces for that account; the second is the tier's number, and an
  operator override can make them differ.

- Admin account types carry `plan`, `sandbox_limit_override` and
  `comped_contacts`. `max_concurrent_sandboxes` keeps its name and its meaning
  — the cap in force — so nothing reading it breaks.

## [0.1.1] — 2026-08-23

No code change from 0.1.0. This is the first release published by CI through
npm's trusted publishing, so unlike 0.1.0 — which went out from a laptop — the
tarball carries a provenance attestation tying it to the workflow, the
repository and the commit that built it. Verify with `npm audit signatures`.

## [0.1.0] — 2026-08-23

First published release.

### Added

- `fountain.run(prompt, { agent, vault, environment })` — one call that
  provisions a sandbox, runs the agent in it and folds the log feed into an
  answer. `await` it, `for await` it, or read `.textStream`; all three are
  views of one run.
- `fountain.resume(id)` — the sandbox and the agent's session are still there,
  so a follow-up costs one prompt rather than a re-explanation.
- `agents`, `environments`, `vaults` — list, read, create, update, delete, and
  write-only secrets. All of them take a **name** where an id would do.
- `team` — teammates, their standing threads, and their routines.
- Streams that reconnect from a cursor, so a deploy mid-turn neither drops the
  answer nor replays it.
- Errors keyed on the API's `error` code rather than the status, because
  `conversation_busy` is a 400, `sandbox_quota_exceeded` a 429 and
  `provisioning` a 503, and what a caller does about each is unrelated to the
  number. Every error carries `retryable`.
- `run.answer(requestId, optionId)` and `resume(id).answer(...)`, with a
  `{ type: "permission" }` run event, for agents whose `permission_policy` has
  an `ask` entry.
- Types generated from the server's own OpenAPI document, with CI failing on
  any drift between the two.
- A browser entry with no Node built-in reachable from it, and a Node entry
  that adds `~/.fountain/credentials`.

[0.1.1]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/0.1.1
[0.1.0]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/0.1.0
