---
type: ADR
title: "Egress credential brokerage: the sandbox holds placeholders, the broker holds the credential"
description: "Proposed; gate 1a is built and live for one tenant (the maintainer) since 2026-08-25, off for everyone else. Outbound HTTP credentials are attached at a forward proxy the sandbox reaches over HTTPS_PROXY, so the agent process holds only placeholders and the only host it may reach is the broker. Gate 0 passed on 2026-08-24 against a real sandbox: brokered API calls and a private clone with no credential in the sandbox, cross-tenant probe refused, +258ms per request."
tags: [security, secrets, sandbox, egress, governance]
status: draft
adr: "0019"
adr_status: "Proposed"
date: 2026-08-14
generated: { by: human:jhgaylor, at: 2026-08-14T04:45:00-04:00 }
stale_after: 2026-11-24
---

# 0019 — Egress credential brokerage

**Status:** Proposed — **gate 1a is built and live for one tenant.**
`Fountain.Broker` and the provisioning wiring exist on `main` (#1090 PRs 1–3),
behind `BROKER_URL`: blank, and every conversation provisions exactly as it did
before the module existed; set, and only the tenants in `BROKER_TENANTS` are
brokered, for `GITHUB_TOKEN` / `GH_TOKEN` only. The broker is deployed under
Flux in home-cloud (jhgaylor/home-cloud#128: Agent Vault on a CNPG cluster,
published at `broker.inevitable.fyi` by the Traefik TCP router of §11), and
the hosted deployment names **one** tenant, the maintainer's own account
(home-cloud#131, 2026-08-25). Its done-when was observed on a production
Sprites conversation the same day — see *Gate 1a* under *Gates*. Everyone else
is byte-for-byte on the old path. Gates 1b–4 are not built; #1090 is closed
and each later gate gets its own tracker.

**Revised 2026-08-25 (gate 1a).** Building it changed three things below,
each marked in place: §11 is a vault per *conversation*, not per tenant; the
proxy URL in *Gates* is the broker's own listener, not Traefik's front; and the
CA goes through `sudo` because the trust directory is root-owned.

**Revised 2026-08-24.** The four questions the first draft left open are
answered: the vendor (§8), whether brokering is a tenant-facing option (§9),
whether the broker may read request bodies (§10), and where it runs (§11). The
production numbers are refreshed below, and a new Context subsection records
what [0023](0023-persistent-agent-sandbox.md) — which shipped on 2026-08-24,
after this draft — changed underneath it.

**Gate 0 passed on 2026-08-24**, against a real Sprites sandbox provisioned by
production Fountain. What it proved, what it cost and what it found is in
*Gates* below; nothing in the product changed, so the rest of this ADR still
describes behaviour that is not built. The spike ran entirely on configuration
already available to a tenant — an environment, a `limited` network policy and
a setup script — which is why it needed no code and why its results are about
the mechanism rather than about our implementation of it.

Every code reference and every number below was re-checked against `main` and
against production on 2026-08-24. The frontmatter carries no `verified` stamp
because that field records a human reading the code, and this revision's
checking was done by an agent; the claim belongs here, at its true strength,
rather than in a field that says something stronger.

This ADR implements and generalises **[0016](0016-governance-as-an-acp-proxy.md)
§4** (*credential brokerage: the sandbox holds no long-lived secret*), and
concretises the first bullet of its §5 conformance bar (*network egress policy,
expressible per conversation*). It does not supersede 0016. It changes 0016 in
one specific way: **0016 gate 3 is no longer blocked on the base-URL survey**,
because the mechanism chosen here does not need one.

It is also the only governance control on the table with **no dependency on
ACP**. 0014, 0015 and 0016 are a sequence; this is not part of it, and can be
built while that sequence is still being argued about.

## Context

### The sandbox holds every secret, and by default it may reach anything

Two facts compose badly.

**Secrets arrive as plaintext.** `merge_secrets/3`
(`conversation_server.ex:970`) decrypts the environment's and the vault's
secrets with the tenant DEK and merges them; `do_build_sprite_env/4`
(`conversation_server.ex:938`) appends the merged map to the sprite's
environment verbatim. `Fountain.Conversations.Redaction`'s moduledoc records
that they also land in `/home/sprite/.env`, so there is a second copy on disk
that outlives any single process.

**Egress is open unless a tenant says otherwise.** `networking_type` defaults to
`"unrestricted"` (`environment.ex:29`), and `unrestricted` is a no-op —
`apply_network_policy(_handle, %Environment{networking_type: "unrestricted"}, _)`
returns `:ok` without calling the sandbox (`provisioning.ex:271`). A conversation
with no environment at all takes the `nil` clause and is equally unpoliced.

So the normal shape of a Fountain conversation is: a process running untrusted
model output, holding every credential its tenant configured, on a host that can
open a connection to anywhere. A prompt injection does not need a clever exploit
chain; it needs `curl`.

### The control exists, is well designed, and has never once been used

This is the fact that should decide the ADR. Production, measured twice:

| | 2026-08-14 | 2026-08-24 |
|---|---|---|
| Environments with `networking_type = 'limited'` | **0** | **0** |
| Environments with `networking_type = 'unrestricted'` | **20** | **36** |
| Environment secrets (`secrets`) | 56 | 79 |
| Vault secrets (`vault_secrets`) | 22 | 50 |
| Inference credentials | 3 | 6 |
| **Plaintext credentials reaching sandboxes** | **78** | **135** |

Ten days, no change in posture, 73% more exposure. The second column is the
argument the first one only implied.

Two further facts from the same query, neither of which the first draft had,
and both of which make the work smaller than it reads:

- **Two tenants hold every one of those secrets** (of 128 accounts). The
  migration in gates 1 and 2 is a two-tenant migration, one of which is ours.
- **Roughly half of what is stored is not a credential.** Grouping the 129
  environment and vault secrets by key name: 73 are token-shaped
  (`GITHUB_TOKEN` ×31, `RENDER_API_KEY` ×11, `POSTHOG_API_KEY` ×11,
  `HONEYCOMB_API_KEY` ×11, `GH_TOKEN` ×4, `CLOUDFLARE_API_TOKEN`, …), 9 are
  URLs or DSNs, and 40 are not secrets at all (`GIT_AUTHOR_NAME`,
  `BUZZ_RELAY_URL`, `AGENT_APPS_PROJECT_ID`). The classification §7 demands is
  therefore load-bearing rather than ceremonial: a scheme that assumes every
  row in `secrets` is a brokerable HTTP credential is wrong about a third of
  them.

One of those keys is worth naming, because it is the shape of the residual gap
and it is ours: `BUZZ_PRIVATE_KEY` (×6) signs Nostr events inside the process
and talks to a relay over a WebSocket. No header-injecting proxy can broker
it, at any point in the future. It is not an edge case to be closed later; it
is the class §7 says must be labelled.

`NetworkPolicy` is a good piece of design — intent-level, default-deny, with
`allow: []` meaning deny-all and the Sprites fail-open-on-empty quirk absorbed by
the adapter rather than the caller (`network_policy.ex`, and all three providers
advertise `:network_policy` since [0018](0018-sandbox-provider-abstraction.md)).
It has 78 tenant secrets riding past it and has protected none of them, because
using it requires a tenant to know it exists, choose `limited`, and then enumerate
every host their agent will ever need.

**A safety default that requires configuration is not a safety default.** The
lesson is not that tenants are careless; it is that we put the burden in the
wrong place. Any fix that leaves the safe posture opt-in will produce the same
table a year from now.

### `Redaction` is the current mitigation, and it is the wrong shape for this

`Fountain.Conversations.Redaction` scrubs secret values (≥8 bytes) out of log
events at the single write path, deliberately via an ETS registry rather than a
caller-supplied argument, because "redaction a caller has to remember will
eventually be forgotten by a new caller." That reasoning is sound and the module
should stay.

But it protects **the transcript**, not the credential. It stops a secret being
written into Postgres by `env` or `set -x`; it does nothing about a secret sent
over a socket, which is the path that actually matters. Today it is the only
thing standing between a printed credential and a permanent unencrypted copy —
which tells you how much of our secret handling is downstream damage control.

### 0016 §4 named this, and picked a mechanism that does not generalise

0016 §4 states the problem exactly: *"we hand the key to the thing we are
governing, and every control above is theatre once the agent can exfiltrate it
and use it elsewhere."* Its proposed shape is a broker reached by pointing the
runtime's **provider base URL** at Fountain, and it flags the open question:
whether every runtime honours a base-URL override, and whether that is stable
across their point releases.

Two problems with that mechanism, and neither is fatal to 0016's goal — only to
its means:

- **It only reaches inference.** A base-URL override redirects the model API and
  nothing else. Of the 78 tenant secrets above, 3 are inference credentials. The
  other 75 — GitHub tokens, deploy keys, database URLs, third-party API keys —
  are exactly the ones a tenant would most mind leaking, and a base-URL override
  cannot touch them.
- **It depends on each runtime's config surface**, which is why the survey is a
  blocker at all. Four runtimes, each with its own override mechanism, each free
  to change it in a point release.

### What a forward proxy changes

[Agent Vault](https://github.com/Infisical/agent-vault) (Infisical) is a
TLS-intercepting, credential-injecting forward proxy built for this exact
problem. Management API on 14321, proxy on 14322 handling both HTTP
forward-proxy and HTTPS `CONNECT`. The agent points `HTTPS_PROXY` at it and holds
only **placeholder** values (`__anthropic_api_key__`); the real credential is
attached to the outbound request at the proxy. Egress filtering is per agent →
service → endpoint, with `unmatched_host_policy=deny` for strict mode. It logs
authenticated traffic, and ships a TypeScript SDK for minting short-lived tokens
for ephemeral sandboxes — which is precisely our per-conversation sandbox shape.

The mechanism difference is the whole argument: `HTTPS_PROXY` is honoured by the
**HTTP client stack**, not by the application's config surface. It covers every
runtime, every CLI, every MCP server, and every `curl` in a `setup_script`,
without asking any of them to cooperate and without a per-runtime survey.

### 0023 landed underneath this draft

[0023](0023-persistent-agent-sandbox.md) shipped on 2026-08-24: one sandbox can
serve many conversations of an agent, turns can run concurrently on it, and a
parked home is checkpointed. This draft was written against a 1:1 world and
four of its assumptions need restating rather than reinterpreting.

- **§5's "the token is scoped to the Conversation" still holds, and is now the
  only shape that works.** The env is not baked into the machine: each
  `ConversationServer` builds its own `sprite_env` and passes it on every
  `exec` and `spawn` (`conversation_server.ex:1255`), so one machine can carry
  two conversations with two different broker sessions. A token minted per
  *sandbox* would make the proxy's request log unattributable the moment two
  conversations share a machine, which is now the normal case.
- **The session token must never reach the disk.**
  `Fountain.Conversations.Identity.disk_env/1` strips the per-conversation
  pairs before `/home/sprite/.env` is written, precisely because that file is
  shared by every conversation on the machine. The broker session token joins
  `@process_only` next to `FOUNTAIN_TOKEN`. Miss that one line and conversation
  A can read B's token off the disk and spend B's credentials, which is a
  worse failure than the one this ADR set out to fix.
- **A checkpoint outlives the conversation.** Placeholders in a checkpointed
  home are harmless, which is the win. A broker session token in one is a
  credential that survives a park; session TTL must be shorter than a park, and
  a wake must re-mint rather than reuse.
- **`Claude.fall_back_to_api_key/2` is a second injection site**
  (`conversation_server.ex:1819`). It puts a real API key into the sprite env
  *mid-conversation*, after `build_sprite_env` has run. Gate 3 has to cover it
  or the fallback quietly reintroduces the plaintext this ADR removes.

## Decision

**Adopt an egress credential broker: the sandbox receives placeholders and a
proxy address, never a long-lived credential, and the only host it may reach is
the broker.**

The capability is the decision; the vendor is an implementation choice. Agent
Vault is the chosen first implementation, and §8 below says what happens when
that choice needs revisiting.

### 1. Placeholders replace plaintext in the sprite environment

`merge_secrets/3` stops feeding raw values into `do_build_sprite_env/4` for any
secret designated an outbound HTTP credential. The sandbox env carries
`GITHUB_TOKEN=__github_token__`; the real value is loaded into the broker,
server-side, from the same DEK-encrypted storage it lives in today.

**Envelope encryption is unchanged.** `Fountain.Crypto`, the per-tenant DEK and
the `secrets`/`vault_secrets` tables stay exactly as they are — they remain the
system of record the broker is loaded *from*. What changes is custody at the far
end, not storage at ours.

### 2. The network floor is `allow: [broker]`, and it is not optional

Every brokered conversation gets `%NetworkPolicy{allow: [broker_host]}`. Not a
default a tenant may widen — a floor. This is the half of the design that makes
the other half true: placeholders are worthless to an attacker only if the
attacker also cannot reach an arbitrary host to try them against.

Because all three providers advertise `:network_policy`, this is portable. A
provider that could not express egress policy could not host a brokered
conversation, which is 0016 §5's conformance bar applied for the first time
rather than merely stated.

### 3. `networking_type` changes meaning, and `unrestricted` stops meaning "no policy"

Today: `unrestricted` → no sandbox call at all; `limited` → allowlist from
`networking_config.allowed_hosts`.

Under this ADR both are enforced at the broker, and the sandbox floor is
identical in both cases:

- **`unrestricted`** — the sandbox still reaches only the broker; the broker's
  `unmatched_host_policy` is permissive, so the agent may reach any host but only
  ever with the credentials it was granted. The name stays honest: unrestricted
  *reach*, brokered *credentials*.
- **`limited`** — `allowed_hosts` is translated into broker service rules and
  `unmatched_host_policy=deny`. Tenant intent is preserved; enforcement moves up
  a layer and gains per-endpoint granularity it never had.

**This is a semantic change to an existing field, not an addition**, and it is
the part most likely to be got wrong under time pressure. The migration is
tractable only because the answer to "how many tenants depend on today's
`limited` behaviour" is zero.

### 4. The placeholder name is a contract

Fountain emits placeholder names; the broker recognises them. That agreement is
an interface between two systems with separate deploy cycles, and it must be
versioned and tested as one — not derived independently on each side from a
secret's key name. A placeholder Fountain emits and the broker does not know
produces an outbound request carrying a literal `__github_token__`, which fails
in a way that looks like an application bug rather than a config drift.

### 5. The broker token is scoped to the Conversation

The per-sandbox token is minted at provision time and scoped to the Conversation
— the same term every door already resolves to. This is what lets the broker's
request log join the audit trail from [0013](0013-audit-trail.md): the trail
records *intent* (which actor, which conversation, what changed), the broker
records *effect* (what actually left, to which host, with which credential), and
the Conversation id is the only thing that can join them. A broker token not
scoped to a Conversation buys custody and forfeits the audit story.

### 6. Fail closed

The broker is on the critical path (see *Consequences*). When it is unreachable,
provisioning fails and the conversation does not start. We do not fall back to
injecting plaintext, and we do not start a sandbox with no egress policy. A
governance control with a fallback that disables it is not a control — 0016 makes
the same argument about escalation timeouts, and this is the same rule applied to
infrastructure.

### 7. Non-HTTP egress stays out of scope, and must be labelled

A MITM **HTTP** proxy brokers HTTP. It does not broker `git+ssh`, raw TCP, or
anything else. Repository clones over SSH with a deploy key remain a plaintext
long-lived credential inside the sandbox, and `provisioning.ex` has an SSH path.

This is a real residual gap, not a rounding error, and 0016 §2's corollary
applies unchanged: **a credential that cannot be brokered must be labelled
unbrokered in the UI and the API**, rather than quietly counted under a claim
that covers it. The honest version of the pitch is "outbound HTTP credentials are
brokered", and the product surface should say exactly that.

### 8. The vendor is Agent Vault, and the interface is ours

Decided 2026-08-24. Infisical's commercial successor, **Agent Proxy**, reached
GA in July 2026, free on every plan, with 30-odd service presets. It is the
better-supported product and it is the wrong one for us, for a structural
reason rather than a maturity one: Agent Proxy is stateless and **fetches the
credential back from an Infisical project**, so adopting it means mirroring
every tenant secret into a second custodian's control plane and making their
API a hard dependency of provisioning. Agent Vault keeps its own encrypted
store, which we load from the DEK-encrypted tables that stay the system of
record (§1).

So: **run the open-source preview, behind an interface we own.** Concretely,
one `Fountain.Broker` module with the Agent Vault client inside it and the
seam documented — not a behaviour plus a registry. [0018](0018-sandbox-provider-abstraction.md)
earned its abstraction by having three providers; this has one, and the
abstraction is worth building on the day there is a second.

The preview's API is "subject to change" and that cost is accepted knowingly:
the pin is ours to hold, and the alternative moves custody rather than risk.
Agent Vault's own posture is reassuring where it counts — credentials are
AES-256-GCM under a KEK/DEK wrap, the root CA private key is encrypted with the
same DEK, and the sandbox's session token travels as `Proxy-Authorization`, a
hop-by-hop header that never reaches the origin.

### 9. Brokering is a property of the deployment and of the secret, not a tenant setting

Decided 2026-08-24. There is no per-environment "broker this" toggle.

The cost of an opt-in is not the boolean; it is that every secret-touching path
carries two shapes forever, and that the safe one is the one nobody selects.
That is the table in *Context* — a well-designed control, opt-in, at zero
adoption. Repeating it with a second flag would be a deliberate repetition of a
known failure.

Two knobs do the work instead, and neither is a new product surface:

- **Deployment.** A broker is configured or it is not. Self-hosters need that
  switch regardless (see *Consequences*), and it is the honest place for it:
  an instance either brokers or it says plainly that it does not.
- **Secret.** Each secret is brokerable or unbrokerable per §7, which we owe
  the UI anyway, and which a third of what is stored today requires.

Rollout is an operator ratchet, not an option: a per-tenant enable we hold,
flipped tenant by tenant as classification is proven. With two tenants holding
secrets, that ratchet is short.

**The escape hatch is the classification, not a setting.** A tenant who wants a
value in the sandbox anyway, having read everything above, marks the secret
unbrokerable — the same label §7 already requires for the values no proxy can
broker, `BUZZ_PRIVATE_KEY` among them. It stays envelope-encrypted, it is
injected in the clear exactly as today, and both the UI and the API say so.
That is the whole hatch: no new field, no second provisioning path, and the
choice is visible on the thing it was made about.

There is a second, blunter path, and it should be described rather than
advertised: `environments.env_vars` is an ordinary map column and is injected
verbatim, so a value put there reaches the sandbox untouched by any of this. It
is the right home for configuration and the wrong home for a credential, for a
reason that has nothing to do with brokering — unlike `secrets` and
`vault_secrets` it is **not encrypted at rest**. A tenant who moves a token
there to dodge the proxy trades a brokered credential for a plaintext row in
Postgres. `Redaction` still scrubs it from the transcript; nothing else about it
improves.

Stated as one rule: **encrypted storage means brokered delivery, unless the
secret is labelled unbrokerable.** Environment secrets and vault secrets are
the same case here; the Vault primitive's override semantics (vault wins on key
collision) are unchanged, since brokering happens after the merge.

### 10. The broker may read request bodies, and rewriting is not its job yet

Decided 2026-08-24. TLS interception means the broker sees plaintext prompts and
responses; that is accepted deliberately, not tolerated, because content
inspection and eventual rewriting of what goes to and comes back from a model
is wanted product behaviour.

What does **not** follow is that the egress proxy is where rewriting should
happen. At the proxy, model traffic is bytes: four provider dialects, SSE
frames, tool-call deltas, prompt caching, compression. At the ACP seam
([0016](0016-governance-as-an-acp-proxy.md)) the same content is already parsed
into a structure Fountain defined. Rewriting belongs where the meaning is.

The split, then:

- **ACP-borne model traffic** — rewritten at the seam, when 0016 gets there.
- **Everything else** — an MCP server calling a model directly, an agent's own
  `curl` — is invisible to the seam, and is where a Fountain-owned content
  proxy would eventually sit. Chained, not merged: sandbox → Fountain content
  proxy (our CA, sees bodies, holds no credential) → Agent Vault (attaches the
  credential) → origin. Agent Vault accepts absolute-form HTTP, so the inner
  hop need not be intercepted twice.

None of that is in scope for gates 0–4. It is recorded here so the topology
chosen in §11 does not foreclose it, and gate 0 proves the chain is possible
rather than assuming it.

### 11. One instance, one vault per conversation

Decided 2026-08-24 as a vault per tenant; **amended 2026-08-25, on building
gate 1a, to a vault per conversation** (`c-<conversation id>`, created at
provision, deleted when the conversation ends). Two facts forced it. A tenant
who runs two conversations at once with different `GITHUB_TOKEN`s — the
vault-per-launch identity swap the Vault primitive exists for — would load
both into one broker vault under one key, and the last write would win for
both conversations. And the broker's request log attributes a request to a
user or agent token, never to a session token: `actor_type` and `actor_id`
are empty for every vault-scoped session, so a per-tenant vault could never
answer gate 4's "which conversation sent this". The vault name is the join.

The tenant-level guarantee this section cared about is unchanged: a session
is bound to one vault by the token, so no session can read or broker another
vault, another conversation's or another tenant's. What follows still holds.

A single Agent Vault instance serves every tenant, with a session in the
`proxy` vault role per conversation.
Agent Vault's permission model is two independent axes — instance roles
(`owner` / `member` / `no-access`) and vault roles (`admin` / `member` /
`proxy`) — a token scoped to one vault cannot read another, and `proxy` is
exactly "may broker requests, may not read credentials". The streams do not
cross by construction rather than by our discipline.

Three things follow that gate 0 has to hold, not hope:

- **The vault binding must be on the token, not the header.** Agents select a
  vault with `X-Vault`. A session token that honours a header naming someone
  else's vault is a cross-tenant read, so the probe is explicit: take a valid
  session for tenant A, ask for tenant B's vault, require a refusal.
- **The proxy port has to be reachable from third-party sandboxes**, and Agent
  Vault's own guidance is to keep it on a trusted or private network. Our
  sandboxes run on Sprites, E2B and Daytona, so it needs a public address.
  **Not the Cloudflare tunnel** — that was this ADR's first answer and gate 0
  disproved it: an HTTP forward proxy speaks `CONNECT`, which the tunnel does
  not forward. What works, and is what the spike ran on, is a Traefik
  `IngressRouteTCP` matching `HostSNI` with TLS terminated at Traefik on the
  existing `websecure` entrypoint, forwarding plain TCP to the proxy. The
  sandbox then uses an *HTTPS* proxy (`https://…@host:443`), so the hop that
  carries the session token is encrypted rather than clear. The management
  port (14321) is not exposed at all.
- **We cannot co-locate with the sandbox**, which is the deployment Agent Vault
  recommends for latency. Measured at gate 0: **+258 ms per request** —
  0.356s brokered against 0.098s direct from a control sandbox, with about
  150 ms of that being the sandbox-to-broker leg alone. That is the price of
  the broker living in one place and the sandboxes living in another, and the
  self-hosted runner ([0022](0022-self-hosted-runner-provider.md)) is the one
  topology where co-location is available.

One instance holding every tenant's credentials and seeing every prompt is a
large blast radius, and it is not a new one: the app server already holds the
master key and decrypts all of it. Saying so plainly is better than pretending
a second instance per tenant would be operated as carefully.

## Consequences

**A new hard dependency on the provisioning path of every conversation.** Broker
down means no conversation starts anywhere. Today's failure domains are Postgres
and one sandbox provider; this adds a third, and §6 deliberately makes it
fail-closed rather than degrade. That needs an HA story and a monitored SLO
before gate 1, not after.

**The broker can read everything, and that is now a chosen capability.** TLS
interception means plaintext request bodies — every prompt sent to a model API
and every diff sent to GitHub. §10 accepts this rather than merely tolerating
it, because content inspection is wanted. It belongs in the security posture
docs and in any DPA regardless, and it raises the bar on where the broker runs
(§11) and who can read its logs. The honest framing for a customer is that the
broker sees what a proxy sees; a claim that it does not would be false the day
we ship it.

**Latency on every outbound request**, paid by the agent rather than by a tool
call. Distinct from 0016's PDP latency, which lands per tool call; these
compound if both ship. A number belongs in gate 0's success criteria.

**`Redaction` becomes defence in depth instead of the front line** — and should
be kept exactly as it is. Placeholders in the environment mean the values it
registers are mostly worthless, which is the point; the ≥8-byte floor and the
single-write-path design are still correct for everything that is not brokered.

**A metering and model-policy position falls out for free.** 0016 §4 wanted the
inference broker for two reasons — custody and a usage-based revenue line. A
proxy that sees every request to `api.anthropic.com` can meter and can enforce
model choice. This ADR does not decide to do either; it notes that adopting it
does not forfeit them, which was 0016's worry.

**Self-hosters inherit another service.** The self-host story
([0011](0011-self-host-first-admin-bootstrap.md) and the 2026-08 audit) gets a
new component with its own database. §9 resolves the tension by putting the
switch at the deployment: an instance with no broker configured keeps today's
behaviour and says so, and one with a broker brokers everything classified
brokerable. What is not on offer is a per-environment toggle that lets a
brokered instance run unbrokered conversations quietly.

**0008's economics are untouched.** [0008](0008-byo-inference-credentials.md) is
still the tenant's key and still the tenant's bill; only custody moves, exactly as
0016 §4 argued.

**We would be claiming something buyers check.** "The agent never holds your
credentials" is verifiable by a customer in about five minutes, which is the
point of saying it — and also means an unbrokered path we failed to label is a
found defect rather than a missing feature.

## Gates

**Gate 0 — passed 2026-08-24.** Agent Vault deployed in the home cloud
(`agent-vault` namespace, SQLite on a volume, telemetry off — it defaults on),
published at `broker.inevitable.fyi` by the Traefik TCP router in §11. Two
vaults, `tenant-a` and `tenant-b`, a `proxy`-role session per sandbox, and
`unmatched_host_policy=deny` set explicitly, because **the default is
`passthrough`** and there is no CLI flag for it — only
`PATCH /v1/vaults/{name}/settings`.

The whole gate ran on configuration a tenant already has: an environment
carrying the proxy variables and a placeholder, `networking_type: limited`
with the broker as the single allowed host, and a setup script as the probe.
No Fountain code changed, which is why these results describe the mechanism
rather than our implementation of it. It was also the **first `limited`
environment this deployment has ever had**, so `apply_network_policy/3` ran in
production for the first time.

| | result |
|---|---|
| brokered call | `api.github.com/user` → 200 as the real account, and a **private repository cloned** over HTTPS, from a sandbox that held no credential |
| no credential in the sandbox | `GITHUB_TOKEN` is 16 bytes beginning `__g`; `/home/sprite/.env` carries the placeholder |
| unmatched host | `example.com` → 403 at the broker |
| cross-tenant probe | tenant-b's session, with `X-Vault: tenant-a` spoofed, → 403. The vault binding is on the token, not the header |
| latency | **+258 ms** per request (0.356s brokered, 0.098s direct from a control sandbox) |
| provisioning cost | **≤170 ms** to mint a session, including exec overhead |
| broker killed mid-turn | fails closed, and reports the wrong thing — see below |
| chained hop | absolute-form HTTP through the proxy → 200, so §10's content proxy can sit in front without a second interception |

Four findings that change the work rather than confirming it:

- **The proxy URL carries both userinfo fields, and both are load-bearing.**
  With only the token, curl works and **git prompts for a *proxy* password and
  aborts** — an error naming the broker, not the repository, which is the sort
  of thing that costs an afternoon. Gate 1a builds it as
  `http://<session-token>:<vault>@host:port` (corrected 2026-08-25: gate 0's
  `https://…@host:443` was the Traefik front in §11; the broker's own listener
  is plain HTTP, and the sandbox trusts its CA for the intercepted upstream).
- **The CA belongs in the operating system trust store, not in per-tool
  variables.** One `update-ca-certificates` satisfied curl, git and npm at
  once (gate 1a adds `NODE_EXTRA_CA_CERTS` for Node, which reads its own
  bundle, and writes the PEM to `/tmp` first: the trust directory is
  root-owned, so it is `sudo install`ed there the way apt is reached). The variable route is worse than useless when a path is wrong:
  `CURL_CA_BUNDLE` pointing at a missing file makes curl fail with no
  fallback, and `NODE_EXTRA_CA_CERTS` alone left npm on "unable to verify the
  first certificate".
- **Deny-by-default finds egress nobody had enumerated.** Provisioning needs
  `registry.npmjs.org` in the vault or the ACP adapter never installs, and the
  turn then failed with `Forbidden: No broker service matching host
  "opencode.ai:443"` — opencode routes model traffic through its own gateway
  rather than the provider's API. Gate 3 is therefore not only about inference
  credentials: every runtime brings its own hosts, and the broker is the thing
  that makes them visible.
- **Fail-closed happens, and says the wrong thing.** With the broker scaled to
  zero every call returned 000, the setup stage still reported `exit_code: 0`
  and `done`, and the conversation died at `{:opencode_install_exit, 1}`.
  Nothing anywhere said "broker unreachable". §6 is satisfied by accident
  today; gate 1 owes it a preflight.

Two things this ADR argued from reading the code are now observed: the session
token does reach the shared `/home/sprite/.env`, and `Redaction` scrubs the
placeholder along with everything else, so probes have to print lengths rather
than values.

**Gate 1a — built and flipped for one tenant, 2026-08-25 (#1090, closed).**
The narrower slice #1090 argued for: catalog bindings only (`GITHUB_TOKEN` /
`GH_TOKEN` to `api.github.com` as a bearer and to `github.com` as basic
`x-access-token`), one operator-held tenant list, no schema change. Verified
end to end against a real Agent Vault and a Linux runner with no cloud in the
loop: a private clone with a 16-byte placeholder in the sandbox, the token off
the shared `.env`, a stopped broker refused by name before any sandbox exists,
and the vault deleted with the conversation. Then on production, on the
maintainer's account, on Sprites: the private clone with a 16-byte
placeholder, `HTTPS_PROXY` absent from `/home/sprite/.env`, and **direct egress
refused** by the `allow: [broker]` floor while the same hosts answered through
the proxy — the one line a runner cannot show, since it has no network policy
(a runner needs `BROKER_ALLOW_UNENFORCED` and is for development only). The
turn's own model calls and the ACP adapter's npm install passed through the
proxy as passthrough, which is gate 3's shape already visible in the broker's
request log. The placeholder is **not** a lookup key — the broker
replaces the auth header wholesale — so the "contract" below reduces to a
plausibility rule.

**Gate 1 — the placeholder contract.** Naming scheme, versioning, and a test that
fails when the two sides disagree. Then all environment and vault secrets that
are outbound HTTP credentials, with the ones that are not explicitly classified
and labelled per §7 — a third of what is stored, on today's numbers. Two items
0023 adds: the broker session token joins `Identity`'s `@process_only` so it
never reaches the shared `/home/sprite/.env`, and the session TTL is shorter
than a park so a checkpoint cannot carry a live token — noting Agent Vault's
TTL floor is 300 seconds and its default is 24 hours. Gate 0 adds three more:
the proxy URL shape above, the CA into the trust store rather than into six
variables, and a broker preflight at provision time so an unreachable broker
says so.

**Gate 2 — `networking_type` migration.** `allowed_hosts` translated into broker
service rules; both modes enforced at the broker; the floor made
non-negotiable. Cheap today precisely because zero environments use `limited`;
this gate gets harder the longer it waits.

**Gate 3 — inference credentials through the same path.** This absorbs 0016 gate
3 and closes its base-URL question: brokering inference through the proxy needs no
override survey. Includes `Claude.fall_back_to_api_key/2`, the second injection
site 0023's Context subsection names. 0016 §4's second purpose (metering)
becomes available here and remains a separate decision.

**Gate 4 — the joined trail.** Broker request log correlated to Conversation, and
whatever surface makes the effect half readable next to the intent half. Gate 0
read that log: it carries `matched_service`, `credential_keys`, `status` and
`latency_ms`, and it carries `actor_type` and `actor_id` that come back
**empty** for a vault-scoped session. So the join needs something the session
alone does not give — an agent entity per conversation, or a vault per
conversation — and that choice belongs at the front of this gate rather than
at the end of it.

Gates 0–2 are the security argument and are worth building on their own. Gates 3
and 4 are where this ADR meets 0016, and neither is blocked on any ACP work.

## Alternatives considered

- **Do nothing; make `limited` the default and document it.** Cheapest by far and
  genuinely better than today. Rejected as sufficient because a host allowlist is
  the wrong granularity: it decides per host while a credential is per
  credential, so any host an agent may reach it may reach carrying every token it
  holds. It also leaves the tenant enumerating hosts, which is the burden that
  produced 0 of 20 adoption.
- **0016 §4 as written — base-URL override only.** Covers 3 of 78 secrets and
  requires a per-runtime survey that is still unblocked. Not rejected so much as
  superseded by a mechanism that gets the same result for all secrets with no
  runtime cooperation.
- **Build our own credential proxy.** We would own the TLS interception, the CA
  distribution into sandboxes, the rule engine, and the request log. That is a
  product, not a component, and 0016 §5's reasoning about not competing with
  better-funded companies applies with more force here than it did for sandboxes.
  Revisit only if §8's vendor decision has no acceptable answer.
- **Short-lived credentials instead of brokered ones** — mint a 5-minute GitHub
  token per conversation rather than proxying. Strictly better where the upstream
  supports it, because there is no proxy on the path at all. Rejected as the
  general answer because it is per-provider: it exists for GitHub and the big
  clouds and does not exist for the long tail of API keys tenants actually store.
  Worth doing *in addition*, for the providers that support it.
- **Enforce with per-process network namespaces inside the sandbox.** Finer
  grained and no external dependency. Rejected because it is per-provider
  substrate work we would have to build three times, and it still leaves the
  credential inside the blast radius — it restricts where a secret can go without
  changing the fact that the agent has it.
- **Wait for the ACP gateway and do this inside it.** Attractive as a single
  coherent story, and wrong on sequencing: egress is the control 0016's own reach
  table marks as the one ACP *cannot* see, so waiting for ACP to fix it is waiting
  for the wrong thing. 0016 already names the signal — if buyers ask about egress
  before approvals, the substrate is the product.
