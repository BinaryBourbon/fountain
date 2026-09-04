---
type: ADR
title: "First-party extensions: Buzz becomes an OTP app installed at build time and enabled at runtime"
description: "Buzz leaves the Fountain core as fountain_buzz, an AGPL OTP application depending on :fountain that the host reaches only through six Fountain.Extension callbacks. Build-time install, runtime enable, no hot code loading. The bundled image keeps every Buzz path, command and provider behavior; a new -core image carries none of it. Built so far: the seam itself (gate 2, #1505) — the registry, the authenticated /api/<prefix> dispatch and the conversation MCP fan-out. Buzz has not moved."
tags: [buzz, extensions, packaging, architecture, licensing]
status: stable
adr: "0043"
adr_status: "Accepted"
date: 2026-09-03
generated: { by: claude-opus/5, at: 2026-09-03T17:00:17-04:00 }
verified: { by: claude-opus/5, at: 2026-09-03T17:00:17-04:00 }
stale_after: 2026-12-03
---

# 0043 — First-party extensions: Buzz becomes an OTP app installed at build time and enabled at runtime

**Status:** Accepted — **partially built.** Gate 2 (#1505) is built:
`Fountain.Extension`, `Fountain.Extensions` and the two runtime seams (the
authenticated `/api/<prefix>` dispatch and the conversation MCP fan-out) exist
and are exercised by fixture extensions. **Not built:** the migration and
OpenAPI composition (`migrations/0`, `openapi_paths/0`, gate 3 / #1506),
`apps/fountain_buzz` and everything that moves into it (gates 4-6 / #1507-#1509),
and the `-core` image and the graduation (gate 7 / #1510). Buzz is still core
code and is still called directly from `Conversations.McpServers`.

ADR [0020](0020-buzz-as-a-client-of-the-acp-gateway.md)'s hosted harness and
brokered signer ship in the image today and keep working unchanged throughout.
The "what Buzz occupies today" inventory in *Context* was read off `main` at
e44c5c89 and is accurate as of 2026-09-03; the PR that builds each gate removes
the corresponding caveat here.

## Context

### Buzz is a product integration wearing a core's clothes

ADR 0020 decided that Fountain hosts `buzz-acp` and brokers the Nostr signature,
so an agent's whole Nostr presence runs at the gateway and the sandbox holds
neither the relay connection nor the identity key. That decision was right and
is live. The way it landed is the problem: it landed *in the core*, and it now
crosses every layer of the server.

Read off `main`, the surface is:

| Layer | What Buzz owns there |
|---|---|
| Context | `Fountain.Buzz` (534 lines), `Fountain.Buzz.{BuzzIdentity,BootSweep,Harness,Manager,Mcp}` (909 lines) |
| Supervision | `Fountain.Application` starts `Fountain.BuzzRegistry`, `Fountain.BuzzSupervisor` and `Fountain.Buzz.BootSweep` |
| Turn assembly | `Conversations.McpServers.fountain_served/2` calls `Fountain.Buzz.conversation_mcp_servers/2` first of four |
| HTTP | `FountainWeb.Router` declares `/api/buzz/agents` (4 actions) and `/api/mcp/buzz/:conversation_id` |
| OpenAPI | `FountainWeb.Schemas` defines `BuzzIdentity`, `BuzzProvisionRequest`, `BuzzAccessUpdateRequest` and two response wrappers |
| Database | `buzz_identities` and two ALTERs, in the main `priv/repo/migrations` path |
| Config | `config/runtime.exs` sets `:buzz_acp_path`, `:buzz_acp_base_url`, `:fountain_cli_path` |
| Assets | `priv/buzz-acp-launch.sh`, `priv/buzz-base-prompt.md` |
| Image | a `buzzacp` Docker stage, `buzz-acp.version` / `buzz-acp.source`, `.github/workflows/buzz-acp-publish.yml`, a smoke check in the runtime layer |
| Go CLI | `cli/internal/cmd/buzz.go` and `cli/cmd/buzz-backend-fountain` |
| Docs | `docs/integrations/buzz.md`, `docs/catalog/mcp-servers/fountain-buzz.md`, a `/buzz-launch` marketing page |

Two facts about that table are load-bearing for what follows.

**The host→Buzz call surface is already tiny.** Outside `lib/fountain/buzz/`
and the two Buzz controllers, the core references Buzz in exactly three places:
the three child specs in `Fountain.Application`, one line in
`Conversations.McpServers`, and two `resources`/`post` lines in the router. The
mess is not entanglement; it is *placement*. That is why an in-process
extraction is credible at all.

**The Buzz→host call surface is small and ordinary.** `Fountain.Buzz` uses
`Accounts`, `Agents`, `Vaults`, `Environments`, `Conversations`, `Crypto`,
`Audit` and `Repo` — public tenant-scoped context APIs, the same ones a
third-party extension would use. It reaches nothing private.

### Why this is not ADR 0037's problem

ADR [0037](0037-component-libraries.md) extracted nine subsystems as
`managoat_*` libraries: Apache-2.0, `Managoat.*` namespace, **no reference back
into Fountain**, published on hex for anyone. Buzz fails every one of those
tests. It owns a table and a tenant-scoped context; it calls eight Fountain
contexts by name; it is useful to precisely one product. Packaging it as a
`managoat_*` library would either strand the database half in core (leaving the
product integration exactly where it is) or push Fountain's schema and contexts
into an Apache library that pretends to be reusable.

So Buzz needs the other shape: not a *component library* Fountain depends on,
but an *extension* that depends on Fountain.

### Why decide now rather than during the extraction

[#1502](https://github.com/BinaryBourbon/fountain/pull/1502) is open and adds a
per-tenant ceiling and a credit gate to hosted Buzz agents. Every such change
deepens the crossing and makes the boundary harder to draw later. More to the
point, the six implementation gates on #1503 each contain an architectural
question — where do migrations run, who owns the OpenAPI paths, what does the
router forward, what happens to the CLI — and answering those one PR at a time
is how a boundary gets decided by accident. This ADR answers them once so the
gates are implementation.

## Decision

**Fountain grows a first-party extension seam: an extension is an OTP
application that depends on `:fountain`, is chosen at build time, enabled by
configuration at runtime, and reached by the host only through a fixed set of
`Fountain.Extension` callbacks. Buzz is the first one.**

### 1. Build-time install, runtime enable. Hot installation is out of scope.

An extension is compiled into the release. Enabling it is a configuration
change; installing it is a rebuild. Hot code installation into a running
release — fetching a package, loading BEAM files, running its migrations,
composing its routes, rolling that back on failure, and carrying native
executables through all of it — is **explicitly not being built**, and this ADR
is the record that it was considered and declined (see *Alternatives*). Nothing
in the callback set below assumes a future in which it becomes possible; if it
ever does, that is a new ADR.

### 2. The host knows descriptors, never modules

```elixir
# config/runtime.exs — the bundled distribution
config :fountain, :extensions, [FountainBuzz.Extension]
```

`apps/fountain` contains no reference to `FountainBuzz` in any form: not a
module, not an atom, not an alias in a comment. It reads the configured list
and calls the behaviour. The direction is `fountain_buzz -> fountain`, and the
umbrella's dependency resolution proves it at compile time.

### 3. `Fountain.Extension` has six callbacks, and no seventh without an ADR

Each replaces exactly one thing the core hard-codes today.

| Callback | Replaces | Contract |
|---|---|---|
| `id/0 :: atom()` | — | Stable identifier. Namespaces routes, telemetry and error payloads. `:buzz`. |
| `enabled?/0 :: boolean()` | `File.exists?(buzz_acp_path)` in `runtime.exs` | Asked before every dispatch, so it must be cheap. An installed-but-not-enabled extension mounts nothing and contributes nothing, and is indistinguishable from an absent one — answering `false` is a supported state, not an error. |
| `migrations/0 :: [{otp_app, path}]` | `buzz_identities` sitting in the core migration path | Appended to `Ecto.Migrator.run/3`'s paths by `Fountain.Release.migrate/0` and the boot migrator, after the core's, so core ordering never depends on an extension being present. |
| `api_prefix/0 :: String.t() \| nil` | the router's Buzz path segments | One lowercase `/api` segment. Validated at boot for shape, uniqueness and collision with a core route, so a bad prefix is a failed deploy rather than a route that quietly serves nothing. |
| `api_plug/0 :: Plug.t() \| nil` | the router's Buzz lines | Mounted **inside** the existing `:api` pipeline by `FountainWeb.Plugs.ExtensionDispatch`, declared last so core routes always win, and called with the prefix moved from `path_info` to `script_name`. Authentication, the rate limit, `current_user` and the request audit stay host-owned; there is no prefix an extension can choose that reaches its plug without them. |
| `openapi_paths/0 :: OpenApiSpex.Paths.t()` | `Paths.from_router(Router)` seeing Buzz routes directly | Merged into the spec after the router's. **This callback exists because a forward is opaque:** `Paths.from_router/1` reads `router.__routes__()`, where a `forward` is one route whose plug is the forwarded router, so the mounted routes are invisible to the spec. Verified in `deps/open_api_spex/lib/open_api_spex/paths.ex`. |
| `conversation_mcp_servers/2 :: [map()]` | the `buzz/2` clause in `Conversations.McpServers` | The one hot-path callback. Called per turn kick with the conversation id and callback token; returns `[]` for a conversation the extension does not claim. Host order is fixed: extensions first, in configured order, then team, team comms, caller. |

**Supervision is not a callback (amended 2026-09-03, #1505).** This table
originally carried a seventh entry, `children/1`, aggregating the extension's
supervision subtree into `Fountain.Application`. Building #1505 replaced it
with the OTP application dependency that was already there: `fountain_buzz`
depends on `:fountain`, so OTP starts the host first and stops it last with no
callback at all. That buys the same ordering guarantee, keeps a crash in an
extension's supervisor off the host's tree by construction rather than by a
`:temporary` child spec, and fixes something the callback had backwards — an
extension's processes now start *after* the Endpoint, which is what a harness
talking HTTP back to this server actually needs. The host aggregates no
extension children.

**Three callbacks that will not be added.** No callback that wraps or vetoes a
host mutation — an extension may call `Fountain.Audit`, `Billing.check_spend/1`
and the context APIs, and may not interpose on them. No second hot-path
callback beyond `conversation_mcp_servers/2`. No callback that returns SQL,
Ecto queries or schema modules for the host to run.

### 4. `fountain_buzz` starts at `apps/fountain_buzz` and may graduate

It begins as an umbrella app, for the same reason every `managoat_*` library
did (ADR 0037, CONTRIBUTING "Adding an umbrella library app"): the compiler
proves the boundary while the host contract is still moving, and a change on
both sides of the seam is one PR rather than a release dance. It graduates to
`BinaryBourbon/fountain_buzz` — **not** `managoat/` — once `Fountain.Extension`
has stopped changing and a second consumer or a second extension has exercised
it. Until then it is `{:fountain_buzz, in_umbrella: true}` in
`apps/fountain/mix.exs`, and, unlike a library, `apps/fountain` may declare it
only in the *bundled* build (see decision 7).

`apps/fountain/test/fountain/umbrella_layout_test.exs` walks `apps/managoat_*`
and does not apply. `fountain_buzz` gets its own guard, asserting the rules that
actually bind it: `apps/fountain/lib` mentions no `Buzz` or `FountainBuzz`
identifier, declares no Buzz route, and holds no Buzz migration.

### 5. AGPL-3.0-or-later, `FountainBuzz.*`, and not a component library

`apps/fountain_buzz/lib` is AGPL-3.0-or-later, like `apps/fountain` (ADR
[0027](0027-agpl-relicensing.md)). It is Fountain-specific product code that
depends on the server; a hosted fork that changes it owes those changes back for
the same reason it does for the server. It carries no hex publication and no
promise of reusability, and it is not named `Managoat.*` — that namespace means
"Apache-2.0 library that does not know Fountain exists", and applying it here
would make the one meaningful thing about the name untrue.

The Go clients keep ADR 0027's other half. `cli/` and whatever `cli/` becomes in
a graduated `fountain_buzz` repository stay **Apache-2.0**: 0027 licenses by
artifact kind, not by repository, and an integrator writing against the Buzz API
should carry no obligation. This repository already holds AGPL `apps/fountain`
beside Apache `cli/`; a graduated extension repository holds the same pair.

### 6. What the bundled distribution promises

The bundled release is **behaviour-compatible across the extraction**. Named
exactly, so a gate PR can be judged against it:

- **HTTP paths are unchanged.** `/api/buzz/agents` (index, create, update,
  delete) and `/api/mcp/buzz/:conversation_id` keep their paths, verbs, request
  and response bodies, status codes and error shapes. The extension mounts at
  those paths; it does not get a `/api/ext/buzz/...` prefix and a redirect.
- **OpenAPI operations are unchanged.** Same `operationId`s, same schema titles
  (`BuzzIdentity`, `BuzzProvisionRequest`, `BuzzAccessUpdateRequest`), same
  positions in `/api/openapi.json`. **The published spec is the bundled spec** —
  the four SDKs generate from it (#1411), so a rename here is an SDK break, and
  there is to be none.
- **The provider protocol is unchanged.** `buzz-backend-fountain` keeps
  protocol_version 1, its `info`/`deploy` ops, and convergence on the Nostr
  pubkey. Buzz's desktop must not notice.
- **`fountain buzz agents ...` keeps working**, from the same `fountain` binary.
- **The Nostr trust boundary is unchanged.** The nsec stays in a vault,
  decrypted server-side into the harness process env; `buzz-acp` holds the relay
  connection; nothing about the identity enters a sandbox. ADR 0020's whole
  point survives the move or the move is wrong.
- **Audit, tenant scoping and billing are unchanged.** `buzz_identity.created`
  / `.updated` / `.deleted` keep their event names and `resource_type:
  "buzz_identity"`; the actors `system:buzz_harness` and
  `system:buzz_boot_sweep` stay in ADR [0013](0013-audit-trail.md)'s closed
  vocabulary, recorded through `Fountain.Audit` — the extension does not get a
  trail of its own. `Billing.check_spend/1` remains the gate.
- **Buzz stays included by default**, in the image the hosted deployment runs
  and every existing self-hoster pulls.

Two things this ADR **declines** to promise, against the tracker's first
reading:

- **The Go CLI does not move for the sake of moving.** `fountain buzz` is a
  thin HTTP client against `/api/buzz/agents` with no Nostr code and no server
  state; subtracting a subcommand from a released binary is a user-visible break
  with nothing bought. It stays in `cli/`, documented as a bundled-distribution
  command that answers `404` against a core server, and stays covered by
  `cli/internal/cmd/docs_test.go`'s diff against `docs/cli.md`.
  `buzz-backend-fountain` is a separate `main` package with its own release
  artifact that Buzz's desktop discovers by name on `PATH`, never through
  `fountain`, so it *does* move to the extension's ownership with no
  compatibility question at all. **#1508 should be rescoped to that split**
  rather than moving both.
- **`conversation_mcp_servers/2` ordering is a host decision, not a promise to
  the extension.** Buzz is first today because it was written first. The
  callback contract fixes "extensions before team", not "Buzz before
  everything".

### 7. Two images from one repository; uninstall is a config change, not a migration

**Distribution.** `ghcr.io/binarybourbon/fountain:vX.Y.Z` stays the **bundled**
image — extension compiled in, `buzz-acp` and `buzz` binaries present — because
that is what runs in production and what every existing tag has meant.
`…:vX.Y.Z-core` is the same tree built without `apps/fountain_buzz` and without
the `buzzacp` Docker stage. Same repository, same version, a tag suffix rather
than a second image name, so nobody has to decide which product they are
running.

**Support.** The bundled image is what the maintainer runs and what a bug report
is triaged against. The `-core` image is CI-verified to boot, migrate, serve
`/api`, pass the OpenAPI validation and run a conversation to completion with no
Buzz application, table or native binary present; it is the supported base for
anyone writing their own extension. A Buzz-shaped report against `-core` is
closed as not-installed, not as a bug.

**Uninstall.** Removing an extension from `:extensions` stops its supervision
subtree, unmounts its routes and drops its OpenAPI paths. It does **not** roll
anything back and does not delete a row.

- **Migrations stay applied.** `buzz_identities` is tenant data, not extension
  scaffolding. Rolling it back is an explicit operator act against the
  extension's migration path, never a side effect of a config change or an
  image swap, and a bundled→core downgrade leaves the table present and unused
  so that swapping back converges instead of reprovisioning.
- **Identity rows survive, and keep cascading.** The foreign keys to `users`,
  `agents` and `vaults` are `on_delete: :delete_all` in the schema, so ADR
  [0009](0009-account-deletion-and-export.md) account deletion stays correct
  whether or not the code that reads the table is loaded. This is the reason
  the table is not conditional on the extension.
- **The one thing uninstall must do is stop.** Harnesses terminate, so the
  agents' Nostr presence leases expire at the relay within 180s rather than
  leaving a hosted agent that looks online and answers nothing.
- **A core release that never installed the extension never creates the
  table**, and its account deletion is correct for the same reason: there is
  nothing to cascade.

## Consequences

- **The compiler becomes the boundary check, in one direction only.**
  `fountain_buzz -> fountain` is enforced by dependency resolution.
  `fountain -/-> fountain_buzz` is enforced by a guard test, because a stray
  atom, string or comment compiles fine. That test is part of gate #1507, not
  an afterthought.
- **The host grows a seam it did not have, and pays for it.**
  `Fountain.Application`, `Fountain.Release`, `FountainWeb.Router`,
  `FountainWeb.ApiSpec` and `Conversations.McpServers` each gain an extension
  dispatch. Five small indirections in exchange for one product integration
  leaving the core, and for the next one costing nothing.
- **The release matrix roughly doubles.** Two images per tag, two boot checks.
  The `-core` build is cheaper (no `buzzacp` stage, no downloaded binaries) but
  it is a second thing that can go red on a release, and the release-verification
  memory of this repo says an image that fails to build silently is the failure
  mode to design against.
- **`Fountain.Buzz` → `FountainBuzz` renames modules, not data.** Audit event
  names, `resource_type` strings, table and column names, config keys, env var
  names and API field names all stay. A rename that reached any of those would
  break decision 6.
- **`ee/` and the extension are independent axes.** Credits (`ee/`, Elastic
  2.0) gate hosted Buzz agents through `Billing.check_spend/1`, a host API; the
  extension (AGPL) calls it like any other caller. Neither directory learns
  about the other.
- **This is the template for the next one.** Team comms, the Gmail tools and
  the caller-tool bridge sit in the same `fountain_served/2` list with the same
  shape. None of them moves in this campaign, and if `Fountain.Extension` turns
  out to fit them, that is the evidence that justifies graduating it.
- **What we give up:** a `managoat_buzz` library that other people could use.
  Nothing about hosted Buzz agents is useful without Fountain's tenants,
  vaults, agents and conversations, so there was nothing there to give.

## Alternatives considered

- **Leave Buzz in the core.** Rejected: it is the only place in the server
  where one external product's integration owns a supervision tree, a table, a
  route namespace, OpenAPI schemas, two native binaries and a CI workflow. Every
  new Buzz feature widens that, and a self-hoster with no interest in Nostr
  ships and boots all of it.
- **A database-free `managoat_buzz` component library (ADR 0037's shape).**
  Rejected: it would extract the process and tool layer, which is the easy
  half, and leave `Fountain.Buzz`, `buzz_identities`, the controllers, the
  routes and the OpenAPI schemas exactly where they are. The core would keep
  every crossing this campaign exists to remove, and gain a package boundary in
  the middle of the harness.
- **An external sidecar or service.** Rejected for the first extraction, not
  forever. It gives the strongest boundary and takes on the most: its own
  datastore or a second path into Fountain's, its own delegation of tenant
  scoping and audit, network hops inside a turn, its own deployment, health,
  scaling and on-call. ADR 0020 already decided the harness lives inside the
  Fountain OTP app rather than a sidecar (gate 2, 2026-08-16), for reasons —
  vault decryption server-side, `Lifecycle` as the reaper backstop — that have
  not changed.
- **Runtime / hot plugin installation.** Deferred with no date. It would need
  package fetch and verification, code loading, migration execution and
  rollback, route and spec recomposition, and native asset placement in a
  running container — and the only user need it would serve is one nobody has
  asked for, since the people who install extensions here are the people who
  build the image. Decision 1 is the record; revisit only against a concrete
  demand.
- **Ship two products with two names** (a "Fountain" and a "Fountain Buzz
  Edition"). Rejected: one product, one version, one tag suffix. Two names
  would make every issue start with "which one are you running".

## Gates

Each gate is a sub-issue of [#1503](https://github.com/BinaryBourbon/fountain/issues/1503),
each leaves bundled behaviour green, and **none is built**.

1. **#1504 — this ADR.** Accepted and indexed.
2. **#1505 — the seam.** `Fountain.Extension` with `id/0`, `enabled?/0`,
   `api_prefix/0`, `api_plug/0` and `conversation_mcp_servers/2`; the host
   dispatches for each; fixture extensions in `test/support` prove the
   contract without Buzz. **Built** ([#1515](https://github.com/BinaryBourbon/fountain/pull/1515)),
   which also dropped the `children/1` callback for the OTP application
   dependency (see decision 3) and made `api_scope/0` the two callbacks
   `api_prefix/0` + `api_plug/0`, so the host validates the prefix without
   unpacking a tuple.
3. **#1506 — composition.** `migrations/0` and `openapi_paths/0`: the migrator
   runs extension paths after the core's, and the spec merges extension paths
   after the router's, with `mix openapi.spec.json` byte-identical for the
   bundled build before and after.
4. **#1507 — the move.** `apps/fountain_buzz`, `Fountain.Buzz*` renamed
   `FountainBuzz.*`, its table, controllers, schemas, launch script, base
   prompt and tests with it; the guard test asserting `apps/fountain/lib` is
   Buzz-free.
5. **#1508 — the Go split.** `buzz-backend-fountain` moves to the extension's
   ownership; `fountain buzz` stays in `cli/` (decision 6). Rescope the issue.
6. **#1509 — the supply chain.** `buzz-acp.version`, `buzz-acp.source`,
   `buzz-acp-publish.yml` and the `buzzacp` Docker stage become the extension's,
   and the bundled image assembles them as an extension layer.
7. **#1510 — graduation and distributions.** The `-core` image and its boot
   check, the docs move, and — only once `Fountain.Extension` has stopped
   moving — `BinaryBourbon/fountain_buzz`.
