---
type: ADR
title: "Component libraries, extracted umbrella-first under the Managoat namespace"
description: "Fountain's database-free subsystems (sandbox, ACP peer, MCP authorization discovery, broker, runner protocol, docs, OAuth, substitution) are extracted one at a time as Apache-2.0 libraries named Managoat.*, first as apps in this umbrella and then as managoat/<name> repos on hex. The first, managoat_substitution, is built (#1347) along with the umbrella mechanics; the other eight are not."
tags: [architecture, libraries, licensing, ci]
status: stable
adr: "0037"
adr_status: "Accepted"
date: 2026-09-01
generated: { by: human:jhgaylor, at: 2026-09-01T20:00:00-04:00 }
verified: { by: human:jhgaylor, at: 2026-09-01T20:00:00-04:00 }
stale_after: 2026-12-01
---

# 0037 — Component libraries, extracted umbrella-first under the Managoat namespace

**Status:** Accepted, 2026-09-01. The tracker is #1334. **Built so far:**
`managoat_substitution` (#1347), with the umbrella mechanics this ADR names
below: the library test step whose coverage joins the merged gate
(`scripts/test-libraries.sh`), the Dockerfile `COPY` per library, and the
guard that pins the dependency direction
(`apps/fountain/test/fountain/umbrella_layout_test.exs`). **Not built:** the
other eight libraries (sandbox, MCP authorization, ACP, broker, runner
protocol, docs, OAuth, credits) and the graduation recipe (#1345). Each PR
that extracts a library updates this block.

Extends [0010](0010-ee-directory-boundary.md) (the licence boundary inside
one repo) and [0027](0027-agpl-relicensing.md) (the server's licence). Names
the seams that [0018](0018-sandbox-provider-abstraction.md),
[0014](0014-agent-client-protocol.md), [0019](0019-egress-credential-brokerage.md)
and [0022](0022-self-hosted-runner-provider.md) already drew, and gives them
a package boundary.

## Context

Fountain is one OTP application (`apps/fountain`) plus `ee/`. A survey of the
dependency graph on 2026-09-01, made by counting module references between
`lib/fountain/<context>` directories, found three things:

1. **Three subsystems never touch the database.** `Fountain.Sandbox` with
   its Sprites, E2B and Daytona adapters, `Fountain.Runtimes` (the ACP peer)
   and `Fountain.Broker` hold no reference to `Fountain.Repo` or to any Ecto
   schema. They read configuration, call Req or the Sprites SDK, and return
   results. They are libraries in everything but packaging.
2. **`Conversations` is the hub, not a seam.** It references 26 other
   contexts, and `ConversationServer` alone is 4,489 lines. Every extraction
   ends with `Conversations` calling the new library; it is what remains.
3. **The coupling that resists extraction is uniform, not structural.**
   Configuration is read as `Application.get_env(:fountain, …)` (the sandbox
   adapters read ten keys, the broker nine), telemetry is emitted under
   `[:fountain, …]`, and audit is recorded inside the context. Each is
   mechanical to cut.

Two motivations. First, several of these pieces are useful to anyone
building an agent platform on the BEAM, and today they cannot be used
without taking the whole AGPL server: a sandbox behaviour with an executable
conformance suite over three vendors, an MCP authorization discovery chain
(RFC 9728, 8414, 7591) with an SSRF guard, a client-side ACP session with a
permission policy and a normalised block format. Nothing equivalent to the
first two is on hex; two ACP packages exist at 0.1.x. Second, the server
itself is easier to reason about, test and eventually rebuild when its
database-free parts sit behind package boundaries the compiler enforces.

The managoat GitHub organization exists and holds sixteen repositories, all
of them applications and templates built on the API. It holds no library.

The costs are known from this repository's own history. A change across a
repository boundary is two pull requests, a version bump and a pin (the SDK
release automation, #1305's CLI work). The CI gates here are strict enough
that a solo merge needs `--admin`. A seam that is still moving pays that
cost on every change.

## Decision

Extract the database-free subsystems as separate libraries, one seam at a
time, in this order and with these rules.

**Umbrella-first.** Each library begins life as an app in this umbrella,
`apps/managoat_<name>`, taken by `apps/fountain` as
`{:managoat_<name>, in_umbrella: true}`. The umbrella resolves dependencies
between its apps at compile time, so a seam that is not real fails to compile
before a second repository exists. A library graduates to a repository
`managoat/<name>` when its public surface has stopped moving; the dependency
line then becomes a git tag, then a hex requirement. The recipe for
graduating is a deliverable of its own (#1345) and is written once.

**Namespace.** Modules are `Managoat.<Name>`; hex packages are
`managoat_<name>`. No library module carries the `Fountain` prefix.

**Licence.** Every extracted library is Apache-2.0, with its own `LICENSE`
in its app directory while it is in the umbrella and a line in `NOTICE`
naming it. The server stays AGPL-3.0 (0027) and `ee/` stays Elastic 2.0
(0010). A library that cannot be used inside someone else's product is not
"useful elsewhere", which was the point. The one candidate this rules out
of the shared namespace is the credits ledger in `ee/`; if it is ever
extracted it is its own Elastic-licensed repository.

**Dependency direction.** Acyclic and pinned:

- standalone: `managoat_substitution`, `managoat_mcp_auth`,
  `managoat_broker`, `managoat_docs`, `managoat_oauth`;
- `managoat_acp` depends on `managoat_sandbox`;
- `managoat_runner` depends on `managoat_sandbox`;
- `fountain` depends on every library, and nothing depends on `fountain`.

A library holds no reference to `Fountain.*` or `FountainWeb.*`, reads no
`:fountain` configuration and emits no `[:fountain, …]` telemetry. A test
in `apps/fountain` walks every `apps/managoat_*` directory and fails on any
of the three (`umbrella_layout_test.exs`, built in #1347).

**Configuration and telemetry.** A library reads its own otp_app
(`config :managoat_sandbox, …`) or takes an options map; `fountain`'s
`config/runtime.exs` populates it from the same environment variables as
before. A library emits telemetry under `[:managoat, :<name>, …]` and
`fountain` attaches its handlers there.

**Test support ships in the library.** `Fountain.Sandbox.Fake`,
`SandboxConformanceCase`, `FakeRuntime` and `FakeRunnerDaemon` are the most
valuable part of their packages; they move with the code, not into
`fountain`'s `test/support`.

**Order.** By how stable each seam is today: substitution (#1336, the
mechanics), sandbox (#1337), MCP authorization (#1338), ACP (#1339, after
the peer settles), broker (#1340, after #1148 decides native versus Agent
Vault client), runner protocol (#1341, after sandbox), docs (#1342), OAuth
(#1343), credits (#1344, optional).

**What stays.** The Ecto contexts (accounts, agents, environments, vaults,
team, connections' providers, conversations), the web layer and the API.
They are Fountain the product; their value is the tenant contract, not the
code.

**Not a rewrite.** The server is not rebuilt on the libraries in one
motion. Once the libraries take their weight out of `ConversationServer`,
what is left is orchestration, persistence and PubSub over library calls,
and that remainder is refactored in place with the suite green throughout.
A big-bang rewrite would spend months re-deriving the tenant, audit and
credit rules that `CLAUDE.md` lists as easy to get wrong.

## Consequences

- **The umbrella gains apps, and every gate has to see them.** Format
  (`subdirectories: ["apps/*"]` already), credo (`apps/*/lib/` already),
  dialyzer (root, already), the Dockerfile deps layer (one `COPY` per
  app's `mix.exs`, or `mix deps.get` fails in the image build), the release
  (transitive through `fountain`'s deps), and the test partitions. The
  partition scripts are written against `apps/fountain` and `ee/`; a
  library's tests run as their own step and export coverage into the same
  merge. #1336 settles each of these once.
- **Graduation is the moment the two-repository cost starts**, and it is
  deliberate: a seam graduates when it has stopped moving, not when it is
  extracted. Until then the umbrella gives the compile-time boundary at no
  release cost.
- **`Fountain.<Name>` modules disappear rather than delegate.** The
  libraries are not an API; nothing outside this repository calls
  `Fountain.Substitution`. A delegating shim would be a coverage hole
  with no caller.
- **Hex refuses git dependencies.** `managoat_sandbox` cannot publish while
  it depends on `{:sprites, github: "superfly/sprites-ex"}`; graduation
  needs a hex release of that client or a vendored one. Extraction into
  the umbrella is unaffected.
- **Two ACP packages already exist on hex.** Whether `managoat_acp` builds
  on one for its JSON-RPC and schema layer, or publishes the whole stack,
  is decided in #1339 before that library graduates. It does not gate
  extraction.
- **The credits ledger is the exception that proves the licence rule.** It
  is listed so the boundary is written down, not because extraction is
  assumed.

## Alternatives considered

- **Straight to separate repositories.** Faster to a public repo; every
  cross-seam change is two PRs from day one, on seams that are still
  moving. The umbrella step costs nothing and defers that.
- **Keep the `Fountain.*` namespace and publish `fountain_*` packages.** The
  cheapest move, and every library would carry the product's name into
  someone else's codebase. Renaming later is a breaking change on every
  consumer.
- **MIT instead of Apache-2.0.** Equivalent for consumers; Apache-2.0
  carries the patent grant, and the CLI and SDK already use it.
- **AGPL for the libraries too.** Uniform copyleft, and no downstream
  product could use them. That is the opposite of the goal.
- **Rewrite the server on the libraries in one pass.** See "Not a
  rewrite" above.
- **Extract `Conversations` too, as "the orchestrator".** It is the
  product's persistence and lifecycle model over the tenant tables; there
  is no second consumer for it.
