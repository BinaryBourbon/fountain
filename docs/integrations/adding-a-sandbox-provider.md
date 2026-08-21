# Adding a sandbox provider

Fountain runs conversations on pluggable sandbox backends behind the
`Fountain.Sandbox` behaviour (Sprites, E2B, Daytona and the self-hosted
runner today). This page is the practical checklist for adding another. The *why* behind the seam's
shape lives in [ADR 0018](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0018-sandbox-provider-abstraction.md);
the contract itself is the `Fountain.Sandbox` moduledoc; the executable form
of the contract is `Fountain.SandboxConformanceCase`. When those disagree
with this page, they win. For the same territory from the platform's side of
the table — what we would ask a vendor to support natively, and what each
gap costs us — see [what we need from a
platform](platform-requirements.md).

## Before writing any code: answer six questions

Every hard bug in the E2B and Daytona adapters traced back to one of these.
Answer them against the provider's real API — run the calls, don't trust the
docs. (Both existing adapters shipped with research that was verified against
official specs and *still* wrong on five counts once measured live.)

1. **Identity.** Can you create a sandbox with a name you choose, and fetch
   it by that name? Daytona: yes. E2B: no — the adapter emulates names via
   metadata filters and adopt-on-list. Fountain always minted the name
   (`fountain-<prefix>-<hex>`); your adapter must make create idempotent
   (re-creating an existing name adopts it) and `get` must distinguish
   `{:error, :not_found}` from transient failures — that distinction is what
   protects parked disks from being destroyed on a flaky network call.
2. **Suspend.** Is there a park state that preserves the *disk* at reduced
   cost, and a resume that returns the same disk? Agent memory lives on the
   sandbox filesystem — resume-with-a-fresh-disk is data loss, not a
   degradation. If the provider can't do this, don't fake it: omit the
   `:suspend` capability and `Lifecycle.idle_action/1` will destroy on idle
   instead (honest amnesia beats silent amnesia).
3. **Streaming.** How do you get stdout/stderr of a long-running process,
   live, and — critically — can a *reconnecting* client replay output from
   byte zero? The attach contract requires replay-from-start. E2B's daemon
   can't replay (journaling `tee` shim + tail replayer); Daytona's follow
   websocket turned out to be unusable live (HTTP journal poller instead).
   Expect to build something here; measure the vendor's streaming endpoint
   with raw bytes before trusting it.
4. **stdin.** Can you write to a live process's stdin repeatedly, and send a
   real EOF? ACP turns hold stdin open for the whole turn and write NDJSON
   into it. Daytona's input endpoint EOF'd the pipe after every write — the
   adapter routes stdin through a tail-fed file instead. Also: `write_stdin`
   must be *total* — writing to an exited command returns
   `{:error, :command_exited}`, never crashes the caller.
5. **Exit codes.** Does the provider report a spawned command's exit code
   reliably? Daytona doesn't — the spawn shim writes an exit-sentinel file.
   Never fabricate exit 0; a stream closing without a verdict is only exit 0
   when the contract's close-without-exit rule applies.
6. **Egress.** Is there a deny-by-default network mode with a runtime-
   updatable domain allowlist? If yes, advertise `:network_policy` and
   remember `allow: []` means *deny all*, never a no-op. If it's tier-gated
   (Daytona), document the failure mode: `limited` network environments
   fail to provision on that provider.

Rejected-provider notes worth keeping: Modal was passed over in the original
campaign because its control plane is gRPC-only (everything else here is
plain HTTP + Req); revisit only if that changed or you're prepared to take a
gRPC dependency.

## The code checklist

Registration centers on `apps/fountain/lib/fountain/sandbox.ex`, and the
changeset validations and the schema-enum guardrail derive from
`known_providers/0` — but three lists are still literals and the guardrail
is what catches drift: the `sandbox_provider` enums in
`fountain_web/schemas.ex` (Agent, AgentCreate, AgentUpdate) and the
`SANDBOX_PROVIDER` boot check in `config/runtime.exs`. Budget those edits.

1. **Adapter modules** under `apps/fountain/lib/fountain/sandbox/<provider>/`:
   the adapter (`@behaviour Fountain.Sandbox`), an API client, and whatever
   streaming/command-server processes the provider needs. Keep provider
   secrets out of `Handle.private` inspection (the struct already excludes
   `private` from Inspect — don't defeat that). Normalize every error into
   the taxonomy in the behaviour moduledoc (`:not_found`, `{:unavailable,_}`,
   `{:denied,_}`, `{:rate_limited,_}`, …) in an `errors.ex` — `Fountain.Retry`
   keys retryability off these shapes.
2. **Register it**: add the atom to `known_providers/0`, the module to
   `@default_adapters`, and a `credential_present?/1` clause. "Enabled" is
   exactly "adapter registered AND credential present" — there is no other
   switch, and the agent-form provider select appears on its own once a
   second provider is enabled.
3. **Config**: `config/runtime.exs` env vars (`<PROVIDER>_API_KEY` required,
   plus base URL / image knobs, blank-equals-unset), rows in
   `docs/configuration.md`, `.env.example`, `.env.compose.example`, and
   `docker-compose.yml`.
4. **Conformance**: add a `use Fountain.SandboxConformanceCase, adapter: ...`
   test with Req.Test stubs for the provider API (or, for a provider whose
   sandbox names carry routing, `name: {Mod, :fun, args}` to mint them — the
   runner adapter does this). This is the gate that
   catches contract drift (exec-never-raises, write_stdin totality, replay-
   from-start, one-terminal-frame, `allow: []` is not a no-op, …).
5. **Image**: a Dockerfile under `images/<provider>/` that bakes the `sprite`
   user (passwordless sudo, `/home/sprite`), node/npm/bun/git, the agent
   CLIs, **and a sprite-writable npm global prefix**
   (`npm config set prefix /home/sprite/.npm-global`) — without that,
   provisioning's `npm install -g --silent` fails as a silent exit 243. If
   commands run as a provider-selected user, make sure it's `sprite` (cf.
   `E2B_USER`).
6. **Docs**: an `docs/integrations/<provider>.md` page + `mkdocs.yml` nav
   entry, modeled on `e2b.md` / `daytona.md`.

## Two traps that both existing adapters hit

- **Spawn must not return before the provider acks the process.** The ACP
  peer writes `initialize` within milliseconds of spawn returning; any
  adapter that returns from `spawn` while the daemon-side registration is
  still in flight will fail prod turns with what looks like "process
  exited" (E2B lost this race in ~300ms, PR #693). Block on the daemon's
  start acknowledgment.
- **Local success proves less than you think.** The E2B race passed every
  local run and both full local cycles on latency luck, and Daytona's
  websocket looked fine in unit tests. The verification ladder below exists
  because each rung caught something the previous one couldn't.

## Verification ladder

Run in order; each rung has caught real bugs the previous rung passed:

1. `mix test` — conformance suite green against your Req.Test stubs.
2. **Live adapter smoke** against a real account: every behaviour callback
   exercised, including suspend/resume with a file surviving the round trip,
   attach replay, and egress deny/allow.
3. **Full conversation cycle** locally (`start_conversation` → real model
   turn → idle park → provider-side status check → wake → second turn →
   terminate → provider-side gone), using the custom image.
4. **Prod smoke** after merge+deploy: pin an agent to the provider via
   `POST /api/agents` (`sandbox_provider`), run one conversation through the
   public API, poll **turn status** (not `turn_count` — a failed turn still
   counts), read the answer from `/events`, terminate, and confirm the
   provider account is clean.

Then: the provider's key goes to the Infisical prod project (synced into
`fountain-secrets`, auto-reloads the deployment), and the image needs a
rebuild story (#692 tracks automating that).
