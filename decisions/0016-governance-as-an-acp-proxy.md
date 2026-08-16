---
type: ADR
title: "Governance as an ACP proxy"
description: "Fountain becomes a policy decision point speaking ACP on both sides; the governance proxy in the middle is the product. No policy engine or inference proxy is built."
tags: [acp, governance, product]
status: draft
adr: "0016"
adr_status: "Proposed"
date: 2026-08-09
generated: { by: human:jhgaylor, at: 2026-08-15T21:03:19-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-15T21:03:19-04:00 }
stale_after: 2026-11-15
---

# 0016 — Governance as an ACP proxy

**Status:** Proposed — **the governance layer described here is not built.**
No policy engine and no inference proxy exist in this repo. Two things this
ADR originally listed as missing have since landed: ACP is built, and is the
only path to the agent for claude, codex and opencode
([0014](0014-agent-client-protocol.md) gates 1–4); and the sandbox
abstraction is `Fountain.Sandbox`
([0018](0018-sandbox-provider-abstraction.md)). What remains unbuilt is the
*answering* — Fountain still observes a turn it cannot intervene in. This ADR
records a product shape and the gates that decide whether we take it; the PR
that builds each gate removes its caveat.

This is the third ACP ADR and the only one that is about what Fountain *is*.
[0014](0014-agent-client-protocol.md) proposes Fountain as an ACP client of
the CLIs it runs; [0015](0015-fountain-as-an-acp-agent.md) proposes Fountain
as an ACP agent reachable from an editor. Both are protocol decisions. This
one claims that the reason to do either is that together they put Fountain in
the middle of a synchronous call it can *answer* — and that answering is the
product.

It does not supersede either. It amends how **0014 gate 3** should be read
(see *Reframing 0014 gate 3*), and if accepted it becomes the reason 0014 and
0015 are sequenced the way they are.

## Context

### Fountain can observe. It cannot intervene.

Every runtime we ship runs with its safety rail removed, and 0014 lists the
flags: `claude.ex:39` `--dangerously-skip-permissions`, `gemini.ex:50`
`--approval-mode yolo`, `codex.ex:51`
`--dangerously-bypass-approvals-and-sandbox`, `open_code.ex:46`
`--dangerously-skip-permissions`. This is not carelessness — a headless CLI
has no channel back to a human, so bypass is the only way it runs unattended.

The consequence is that the audit trail from [0013](0013-audit-trail.md) is
**retrospective by construction**. It is an excellent record of what a tenant
changed. It has never been able to say "and this was not allowed to happen,"
because nothing in the system was positioned to prevent anything. The sandbox
is not defence in depth; it is the only defence there is.

Anyone evaluating Fountain on governance grounds asks one question first —
*what stops the agent from doing X?* — and today the only honest answer is
"it is in a sandbox, and afterwards you can read what it did."

### None of the four primitives is a rule

Environment, Vault, Agent and Conversation are all **configuration**: what the
agent has, and what it ran. There is no object anywhere in the system that
expresses *what an agent may do*. Adding governance features to the existing
primitives would mean scattering predicates across four schemas that were
designed to describe capability, not constrain it.

### What ACP actually changes

`session/update` is a notification — a better-typed version of the stdout we
already parse, and on its own it buys a cleaner render path and nothing else.

`session/request_permission` is a **request**. The agent blocks; the client's
answer determines what executes. The same is true of `fs/read_text_file`,
`fs/write_text_file` and `terminal/*`, which the protocol assigns to the
*client*. Once Fountain holds the client role, it is synchronously in the path
of every tool call, file access and command the agent attempts — not as a
listener, but as the thing that decides.

That is the whole of the argument for this ADR. Not that ACP is a nicer
stream format, but that it is the only mechanism on the table that turns a log
into a control, and it does so by being synchronous.

### The reach, and its honest split

"Whatever client, whatever cloud" is the reach of the governance plane, not a
feature list. It splits unevenly, and the split determines the architecture:

| Control | Enforced at |
|---|---|
| Tool-call approval | ACP — `session/request_permission` |
| File read / write | ACP — `fs/*` (client-implemented) |
| Command execution | ACP — `terminal/*` (client-implemented) |
| Model, spend, prompt policy | inference path (see *Credential brokerage*) |
| **Network egress** | **the sandbox substrate — ACP cannot see it** |

Egress is the control most often asked for first and the one the protocol
cannot reach: the agent's network access happens inside the sandbox, below
ACP entirely. It is a property of *where the thing runs*. This is why the
substrate is in scope for a governance ADR at all, and it is the honest
correction to a reading of 0014 in which placement is merely orthogonal —
placement is orthogonal to the *protocol* and load-bearing for the *product*.

## Decision

**Fountain becomes a policy decision point that speaks ACP on both sides.**
The proxy shape from 0014 and 0015 is retained exactly; this ADR adds the
thing in the middle, and says that the middle is what we sell.

```
   whatever client                whatever cloud
  ┌────────────────────┐
  │ editor · web · CI  │◄── escalate ──┐
  │ · chat             │─── answer ────┤
  └─────────┬──────────┘               │
            │ ACP — Fountain as agent  │      (0015)
            ▼                          │
  ╔══════════════════════════════════════════════════════╗
  ║                      fountain                        ║
  ║  ┌────────────────────────────────────────────────┐  ║
  ║  │  PDP — evaluated server-side, always           │  ║
  ║  │  tool_call · fs/* · terminal/* · inference     │  ║
  ║  │  → allow / deny / escalate                     │  ║
  ║  └────────────────────────────────────────────────┘  ║
  ║   audit (0013)  ·  credential broker  ·  metering    ║
  ╚══════════════════════════════════════════════════════╝
            │ ACP — Fountain as client   │ inference proxy
            ▼                            ▼      (0014)
  ┌──────────────────────────────┐   provider APIs
  │ sandbox                      │   (tenant key, held server-side)
  │  claude · codex · gemini · … │
  │  ── egress policy HERE ──    │
  └──────────────────────────────┘
```

### 1. A fifth primitive: Policy

A `Policy` is a tenant-owned, versioned set of rules attached to an agent (and
later to an org or a project), evaluated on every intercepted call, returning
**allow**, **deny**, or **escalate**. It is the first primitive that expresses
what an agent may *not* do, and without it "governance" is the dashboard we
already have.

Deliberately unspecified here: the rule language. Whether it is a small
declarative schema, a matcher over ACP's `tool_call.kind` and `locations`, or
something embeddable is a gate-2 question that should be answered against real
denials rather than in advance. What *is* decided is that rules are data owned
by the tenant, versioned, auditable, and never expressed as code we deploy.

### 2. The PDP is evaluated server-side, always

Never in the sprite, never in the editor, never in `cli/`. The sprite executes
untrusted model output and the editor is a user surface; both are adjacent to
the thing being governed and neither has standing to decide. The proxy shape
is load-bearing rather than incidental precisely because the middle is the
only position with that standing.

Corollary, and it is a hard rule: **a runtime that cannot be made to route its
tool calls through the client is not a governed runtime.** We may still run
it, but it must be labelled ungoverned in the UI and the API rather than
quietly enrolled under a policy that cannot reach it.

### 3. Reframing 0014 gate 3

0014 gate 3 reads as "implement `session/request_permission` against the
conversation LiveView: a real approval prompt." Read through this ADR it is
the wrong shape, and the difference matters:

> Build a PDP. The LiveView prompt is **one of its answer sources**, used only
> when a rule evaluates to *escalate*.

Policy-first, human-second. 0015 already found the failure mode from the other
end — permission forwarding is two hops (sprite → Fountain → editor →
Fountain → sprite) and *what replies when the editor detaches mid-request?* In
a product whose pitch is governance, that stops being an edge case and becomes
core semantics. Four requirements fall out, and none is a polish item:

- **Most decisions are made without a human.** An agent makes many tool calls;
  a design that asks a person about each one is not a governance product, it
  is a captcha.
- **Every escalation carries a timeout, and the default on expiry is deny.**
  Fail-open is not a governance posture, and an escalation nobody will ever
  see is the normal case for a conversation started from CI or left running
  overnight.
- **An escalation holds a sandbox open, so the timeout is a cost control as
  much as a security one.** 0014's *Session lifetime* section binds the ACP
  connection to the turn precisely so that an idle sandbox can be reclaimed,
  and interception is possible only inside that window — which is fine,
  because tool calls only happen inside it too. But a conversation parked on
  an unanswered `session/request_permission` is a turn in flight, and
  `Lifecycle.check/4` suppresses idle reclaim while one is
  (`busy? = state.current_command != nil`, `conversation_server.ex:1263`). So
  a prompt nobody answers bills a sprite up to the 24-hour ceiling with the
  idle timeout disarmed. That is not a hypothetical: #413 produced exactly
  this by accident, and the comment at `conversation_server.ex:1204` records
  the result — "idle reclaim was suppressed (busy? true), the reaper skipped
  the sandbox (server alive), and the sprite billed until max_lifetime."
  Escalation deadlines must therefore be strictly shorter than the idle
  window, and stated as a number rather than inherited from it.
- **The conversation survives a deny.** A denial is an ordinary result the
  agent is told about, not a fault. Anything else hands `SandboxReaper` and
  the rehydrator a hang state neither knows about — which is the exact risk
  0015 names as a precondition for its own gate 4.

### 4. Credential brokerage: the sandbox holds no long-lived secret

[0008](0008-byo-inference-credentials.md) decrypts tenant inference
credentials at provisioning time and passes them to
`runtime_module.default_env(agent, credentials)`, from where they enter the
sandbox as environment variables. Under a governance thesis that is backwards:
we hand the key to the thing we are governing, and every control above is
theatre once the agent can exfiltrate it and use it elsewhere.

The target shape is a broker. The sandbox receives a short-lived,
conversation-scoped token; the runtime's provider base URL points at Fountain;
the tenant's real key stays server-side and is applied on the way out.

0008's core decision survives untouched — it is still the tenant's key and
still the tenant's bill, so the cost-attribution argument and the
Claude-subscription case are unaffected. What changes is custody.

Two things fall out, and both are load-bearing:

- **A fourth chokepoint.** Model selection, spend caps and prompt-level policy
  become enforceable, in a place that already sees every request.
- **A usage-based revenue line.** 0008 gave away the inference margin by
  design and 0005 keeps compute as a cost we recover; if the substrate also
  becomes BYO (below), Fountain is a pure control-plane subscription with no
  metered line at all. The broker is where one could exist without
  reintroducing the problems 0008 rejected.

**Unverified, and a gate-1-shaped question:** whether every runtime honours a
provider base-URL override, and whether doing so is stable across their point
releases. A runtime that does not is a runtime whose inference cannot be
brokered, and by the corollary in §2 it should be labelled accordingly rather
than exempted quietly.

### 5. The sandbox behaviour is defined by a conformance bar, not a cloud list

> **Status note (2026-08-14):** built, with one deviation.
> [0018](0018-sandbox-provider-abstraction.md) supersedes this section's
> two-implementation cap: `Fountain.Sandbox` + its conformance suite exist,
> and the second and third implementations are hosted providers (E2B,
> Daytona) rather than the BYO-Kubernetes runner sketched here — proving
> the seam against differently-shaped backends took priority over waiting
> for a named customer. The conformance bar itself is unchanged.

`Fountain.SpritesClient` is the single sandbox implementation, reached through
a platform-shared token ([0005](0005-platform-shared-sprites-token.md)).
"Whatever cloud" must not become a matrix of providers — that is the entire
product of several better-funded companies, and competing there means shipping
a worse version of somebody's whole business in order to sell something the
customer regards as table stakes.

Instead: **one `Fountain.Sandbox` behaviour whose contract is dictated by what
governance requires**, and a conformance suite that a backend either passes or
does not. The contract must include, at minimum:

- network egress policy, expressible per conversation;
- provisioning that injects no long-lived credential (§4);
- exec with captured output, and stdio attach for the ACP peer;
- guaranteed destruction, on a path the reaper can drive.

A backend that cannot express egress policy cannot host a governed
conversation, whoever owns the cloud it runs in. This inverts the problem from
"support everything" to "here is the bar," which is defensible, testable, and
makes community-contributed backends viable without us owning them.

Two implementations are in scope ever: **Sprites** (today's hosted default)
and **bring-your-own-Kubernetes**. A third is not written until a paying
customer names it.

### 6. Decisions are not mutations

`Fountain.Audit.Event` records `action`, `resource_type`, `resource_id`,
`actor`, `request_ip`, `metadata`. 0013's rule is *only record what happened*
— a rejected changeset records nothing, because a trail that logs attempts as
changes cannot be read literally.

A denied tool call **did** happen, and it is the single most important thing a
governance product records. But it is not a mutation of tenant-owned state,
and forcing it into `audit_events` would break exactly the property 0013 is
built on.

So: a **separate decisions record** — the request, the policy version that
decided it, the verdict, the answer source (rule / human / timeout), and the
latency. Same append-only discipline, same actor vocabulary, its own table and
its own rule. The existing vocabulary is closed and this ADR does not open it;
`sprite` already names an agent acting as the tenant, which is precisely the
principal on the requesting side of every decision.

### Gates

**Gate 0 — one policy, one runtime, end to end.** Not the sandbox behaviour,
and not the four-runtime conversion. 0014 gate 2 for a single runtime, plus a
PDP that can answer exactly one rule — *deny writes outside the workspace* —
with deny-on-timeout, recorded as a decision, on a conversation that survives
the denial. This is the smallest artifact that proves interception,
server-side evaluation, a real deny and survivability. If the deny wedges the
conversation or the added latency is unacceptable, we have learned it for the
price of one runtime rather than a platform.

Two of its success criteria are numbers, not properties, and they should be
written down before the gate starts rather than discovered in it: the added
per-tool-call latency of a *non-escalated* decision, which every tool call
pays; and the escalation deadline, which by §3 must be shorter than
`sandbox_idle_timeout_minutes` and is the difference between a governance
control and an unbounded bill.

**Gate 1 — the chokepoints ACP already gives us.** `fs/*` and `terminal/*`
serviced against the sprite, under policy. 0014 lists these under Consequences
as the likeliest source of a security finding, and that judgement stands:
paths arriving over this channel are untrusted input from a sandbox we do not
fully control, and the absolute-path and 1-based-line requirements are the
protocol's, not ours.

**Gate 2 — the rule language**, chosen against the denials gates 0 and 1
actually produced.

**Gate 3 — the broker.** Blocked on the base-URL survey in §4.

**Gate 4 — the sandbox behaviour and a second implementation.** Blocked on a
named customer, not on a roadmap slot.

Human escalation to an *editor* — 0015's own gate 4 — remains blocked on
everything above, and on 0015's detach question having an answer.

### Not in scope

- **The rule language.** Gate 2, deliberately.
- **Workspace sync and read-through.** 0015 names both as separate decisions
  and this ADR does not smuggle them in; the editor stays a control surface.
- **Governing anything that is not a coding agent in a sandbox.** A general
  policy plane for arbitrary MCP traffic is a larger and different product.

## Consequences

**Tool-layer policy is advisory unless the substrate backs it.** An agent that
can run `bash` routes around fine-grained tool rules; an agent with
unrestricted egress can exfiltrate whatever it can read regardless of what it
was allowed to call. Policy and sandbox are one control split across two
layers, and shipping either alone sells a guarantee we do not have. This is
the most important sentence in this ADR and the easiest one to lose during
implementation.

**Latency lands on every tool call.** A synchronous PDP in the path, and two
network hops whenever a decision escalates to a human. Agents make many tool
calls. A budget for this belongs in gate 0's success criteria, not in a
follow-up.

**We would be betting governance on a young spec.** ACP's remote transport is
documented as work in progress and parts of the adapter ecosystem are
vendor-maintained npm packages versioned independently of the CLIs they wrap
(0014, *supply-chain surface*). A vendor dropping an adapter turns a governed
runtime into an ungoverned one — which means "supported runtime" acquires a
maintenance obligation and a public status, per §2's corollary.

**The JSON-RPC peer must not land in `ConversationServer`.** It is 2,088 lines
today (`apps/fountain/lib/fountain/conversations/conversation_server.ex`).
0014 already says this; adding a PDP call path makes it more true, not less.

**The event stream becomes an interface with a policy dimension.** 0015 notes
that two clients rendering the same stream makes it an interface subject to
the OpenAPI spec and the router-walking guard from the #531 campaign. Decision
records extend that: they are the part a customer will export, alert on and
show an auditor.

**This is a go-to-market change wearing an architecture costume.** Governance
sells to a buyer with procurement, a security questionnaire and a long cycle.
[0005](0005-platform-shared-sprites-token.md),
[0006](0006-hard-stripe-billing-gate-at-launch.md) and
[0007](0007-g3-launch-go.md) describe a self-serve, Stripe-gated product
measured in weekly actives; the `ee/` boundary and the hard billing gate were
built for that company. Adopting this ADR is choosing a different one, and the
code is the cheaper half of that choice. **Nothing in gates 1–4 should start
before that has been decided deliberately** — gate 0 is worth building either
way, because it also settles whether 0014 gate 3 is achievable at all.

**What we give up:** the position that Fountain is a convenience layer over
agent configuration. Today the pitch is that running Claude with worktrees and
hand-shuffled MCP config is painful, and Fountain makes it pleasant. That
pitch is true, it is what exists, and it sells to an individual developer who
also has the option of a free CLI on a laptop. A governance plane is a claim
to be relied upon, and claims that are relied upon come with the obligation to
be right about them.

## Alternatives considered

- **Ship 0014 and 0015 as protocol cleanups and stop.** Real value: a
  deleted render-path parser problem and an editor integration. Rejected as
  the *end state* because it spends the ACP migration and declines the only
  thing it uniquely enables; the parsers can be deleted without ever being
  able to deny anything.
- **Governance as post-hoc detection.** Keep the current architecture, add
  alerting and anomaly rules over the 0013 trail. Much cheaper, ships now, no
  protocol dependency, no latency. Rejected as the primary answer because it
  cannot prevent anything and the first buyer question is prevention — but it
  is a genuinely good *complement*, and if gate 0 fails this is the fallback
  rather than nothing.
- **Enforce entirely at the substrate** — no ACP, no PDP; sandbox network
  policy, read-only mounts, seccomp. Strictly stronger where it applies, since
  it cannot be argued around by a model. Rejected as sufficient on its own
  because it is coarse: it can say "no internet," not "you may open a PR
  against this repo but not force-push to `main`," and the second is the
  granularity the product needs. The right reading is that this ADR needs
  both, which §5 encodes as the conformance bar.
- **Buy or wrap an existing policy engine.** Sensible for the rule language at
  gate 2 and explicitly left open there. Rejected as a *starting point*
  because the hard part is not evaluating a predicate — it is having a
  synchronous position from which the answer matters, which is gates 0 and 1.
- **Lead with the sandbox abstraction, ACP later.** Correct if the first buyer
  conversation is about egress and residency rather than approvals. Named here
  as the alternative sequencing that would replace this ADR's, and the signal
  to watch for: if two consecutive prospects ask about the VPC before they ask
  about approvals, the substrate is the product and the proxy is the sidecar.
