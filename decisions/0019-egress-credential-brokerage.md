# 0019 — Egress credential brokerage

**Status:** Proposed — **nothing described here is built.** No broker is
deployed, no placeholder substitution exists, and `Fountain.Sandbox.NetworkPolicy`
— which does exist — has never been applied to a single production sandbox. This
ADR records a decision shape and the gates that decide whether we take it; the PR
that builds each gate removes its caveat.

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

This is the fact that should decide the ADR. Production, 2026-08-14:

| | |
|---|---|
| Environments with `networking_type = 'limited'` | **0** |
| Environments with `networking_type = 'unrestricted'` | **20** |
| Environment secrets (`secrets`) | 56 |
| Vault secrets (`vault_secrets`) | 22 |
| Inference credentials | 3 |

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

### 8. Vendor risk is a decision, not a footnote

Agent Vault is Infisical's **research preview**, and Infisical has already
announced a commercial successor (Agent Proxy). Once secrets stop being injected
as plaintext, the broker is load-bearing infrastructure on the provisioning path
of every conversation — the least convenient thing to swap under duress.

Gate 0 therefore includes a written answer to: do we run the open-source preview,
adopt the commercial product, or treat the preview as a reference implementation
of an interface we own? The decision is not made here; making it *before* gate 1
is.

## Consequences

**A new hard dependency on the provisioning path of every conversation.** Broker
down means no conversation starts anywhere. Today's failure domains are Postgres
and one sandbox provider; this adds a third, and §6 deliberately makes it
fail-closed rather than degrade. That needs an HA story and a monitored SLO
before gate 1, not after.

**The broker can read everything.** TLS interception means plaintext request
bodies — including every prompt sent to a model API and every diff sent to
GitHub. We would be adding a component that sees more tenant content than
anything else we run, in order to stop leaking credentials. That trade is
probably right and is definitely a trade; it belongs in the security posture
docs and in any DPA, and it raises the bar on where the broker runs and who can
read its logs.

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
new required component with its own database. If brokering is mandatory, the
minimum viable self-host grows; if it is optional, self-hosted instances run the
posture this ADR calls unacceptable. That tension needs an answer, and "optional
but loudly labelled" is the likely one.

**0008's economics are untouched.** [0008](0008-byo-inference-credentials.md) is
still the tenant's key and still the tenant's bill; only custody moves, exactly as
0016 §4 argued.

**We would be claiming something buyers check.** "The agent never holds your
credentials" is verifiable by a customer in about five minutes, which is the
point of saying it — and also means an unbrokered path we failed to label is a
found defect rather than a missing feature.

## Gates

**Gate 0 — one credential, one conversation, end to end.** A broker deployed
somewhere real; one secret converted to a placeholder; `NetworkPolicy` narrowed
to the broker; prove the agent can call `api.github.com` with a credential it
never held, and cannot reach anything else. Success criteria written down first,
as numbers: added per-request latency, provisioning-time cost of minting a token,
and the observed behaviour when the broker is killed mid-conversation. Plus the
vendor decision from §8.

**Gate 1 — the placeholder contract.** Naming scheme, versioning, and a test that
fails when the two sides disagree. Then all environment and vault secrets that
are outbound HTTP credentials, with the ones that are not explicitly classified
and labelled per §7.

**Gate 2 — `networking_type` migration.** `allowed_hosts` translated into broker
service rules; both modes enforced at the broker; the floor made
non-negotiable. Cheap today precisely because zero environments use `limited`;
this gate gets harder the longer it waits.

**Gate 3 — inference credentials through the same path.** This absorbs 0016 gate
3 and closes its base-URL question: brokering inference through the proxy needs no
override survey. 0016 §4's second purpose (metering) becomes available here and
remains a separate decision.

**Gate 4 — the joined trail.** Broker request log correlated to Conversation, and
whatever surface makes the effect half readable next to the intent half.

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
