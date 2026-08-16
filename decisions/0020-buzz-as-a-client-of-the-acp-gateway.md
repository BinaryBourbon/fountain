---
type: ADR
title: "Buzz as a client of the ACP gateway: hosted harness + brokered signing"
description: "Fountain hosts the Buzz harness and brokers the Buzz Nostr signature at the gateway, so the sandbox holds neither the relay connection nor the identity key. Nothing here is built."
tags: [acp, buzz, nostr, gateway]
status: draft
adr: "0020"
adr_status: "Proposed"
date: 2026-08-16
generated: { by: human:jhgaylor, at: 2026-08-16T00:08:11-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-16T00:08:11-04:00 }
stale_after: 2026-11-16
---

# 0020 — Buzz as a client of the ACP gateway: hosted harness + brokered signing

**Status:** Proposed — **nothing here is built.** No hosted-harness supervisor,
no Buzz signer, and no `buzz-backend-fountain` provider exist in this repo. This
ADR records a direction and the gates that decide whether we take it; the PR
that builds each gate removes the caveat on that section. The starting commit is
tagged `pre-buzz-gateway` (last commit before any of this work).

This is the first ADR about integrating with a *specific* external client
([block/buzz](https://github.com/block/buzz)) rather than a protocol. It sits on
top of the ACP decisions: [0014](0014-agent-client-protocol.md) (Fountain as an
ACP *client* of the runtimes), [0015](0015-fountain-as-an-acp-agent.md)
(Fountain as an ACP *agent* an editor drives), and
[0016](0016-governance-as-an-acp-proxy.md) (the governance plane in the middle).
It also depends on the egress/credential thinking in
[0019](https://github.com/BinaryBourbon/fountain/pull/690), and it explains why that ADR's
placeholder-swap mechanism does **not** extend to Nostr.

## Context

### Buzz splits an agent's Nostr work in two, and only one half is in our sandbox today

A Buzz agent is a Nostr identity that participates in relay-based group channels.
Operationally it is two processes, and the names invert what you would guess
(verified in `block/buzz` at main):

- **`buzz-acp` — the harness.** Long-lived. Holds the relay WebSocket, does
  NIP-42 auth carrying the NIP-OA owner attestation tag, subscribes to mentions
  and channel/membership events, runs presence (kind 20001, a lease the relay
  expires after 180s), typing, and 👀/💬 reactions, prefetches the agent's
  engram memory, assembles the system prompt, and drives an ACP agent **over
  stdio**. On Buzz's desktop this process is spawned per agent (a pool of 10).
- **the agent's replies — `buzz-cli`.** `buzz-acp` **never publishes the
  agent's answer**: `handle_session_update` logs `agent_message_chunk` and
  nothing else (`crates/buzz-acp/src/acp.rs`). Channel content is Nostr events
  the *agent* publishes by shelling out to the `buzz` CLI, which the base prompt
  orders it to do ("If your turn produced anything worth knowing, you MUST
  publish it. Use `buzz messages send`. Your reasoning and tool calls are
  invisible.", `crates/buzz-acp/src/base_prompt.md`).

Today Fountain participates by being the ACP agent `buzz-acp` drives: a Buzz
custom-harness entry runs `fountain acp --agent X --vault Y` on the user's
laptop, and the *sandbox* carries the identity — the `buzz` CLI is installed
into the sandbox and the agent's nsec is a vault secret merged into the sandbox
env. So all of the agent's Nostr surface lives on the laptop and in the sandbox.

### The costs of that placement

- **The identity key is in the sandbox env.** Untrusted model output can read
  the agent's *identity*, not a rotatable token. `decrypted_env/2` puts the nsec
  in plaintext where the runtime can see it.
- **Every Buzz sandbox downloads a 115 MB CLI** (the vault-gated `eng`-env
  install), amd64-only.
- **The publish bypasses Fountain entirely.** Sandbox → relay egress is outside
  the audit trail (0013) and any future policy point (0016). Fountain sees the
  ACP turn; it does not see the Nostr event.
- **The agent has a body only while the laptop runs Buzz** — the exact problem
  Buzz's own [remote-agents](https://github.com/block/buzz/blob/main/VISION_REMOTE_AGENTS.md)
  work is trying to solve.

### Why the 0019 egress trick does not extend to this

[0019](https://github.com/BinaryBourbon/fountain/pull/690) brokers API credentials by injecting
*placeholder* values into the sandbox and swapping the real secret onto the
outbound HTTP request at an egress proxy. That works because an API key is a
bearer token the proxy can substitute. A Nostr event carries a **Schnorr
signature over its own content and pubkey** — there is nothing at egress to
swap, and `buzz-cli` signs locally (`nostr::Keys`, NIP-98 per request, no
NIP-46/remote-signer mode). Either the key sits where the CLI runs, or *signing*
moves out of the sandbox. This is the single fact that shapes the whole ADR.

### Spike (2026-08-15): the split is real, measured against prod

Running `buzz-acp` **off the desktop** (a plain process with `BUZZ_PRIVATE_KEY`
/ `BUZZ_AUTH_TAG` / `BUZZ_RELAY_URL` in its env, `BUZZ_ACP_AGENT_COMMAND` set to
`fountain acp`) against `wss://buzz.inevitable.fyi` and prod Fountain: the
harness connected, resolved the owner from the NIP-OA tag, discovered the
channel, received an owner mention, drove a full ACP turn through `fountain acp`
into a Fountain sandbox, and returned `end_turn`. The agent produced the correct
answer text. **No reply reached the channel, and the turn emitted zero tool
calls** — the model answered conversationally and never ran `buzz messages
send`. Inbound moved off the desktop with no code changed; outbound did not move
and cannot without the plumbing below. Both halves of this ADR are therefore
observed, not assumed.

## Decision

**Fountain hosts the Buzz harness and brokers the Buzz signature, so that an
agent's entire Nostr presence runs at the gateway and the sandbox holds neither
the relay connection nor the identity key.** Two independent capabilities, gated
separately:

### Phase 1 — host `buzz-acp` at the gateway (inbound moves)

A Fountain-side supervisor runs one `buzz-acp` process per (agent × Buzz
identity), with the identity env read from a vault **decrypted server-side** and
`BUZZ_ACP_AGENT_COMMAND=fountain acp --agent … --vault …` pointed at Fountain
itself. Everything enters through the existing ACP-agent door (0015), so
Conversation, `log_events`, `Lifecycle` and audit are untouched by construction.
Presence is a lease renewed by the idle harness process (cheap) while the
expensive sandbox suspends per [0017](0017-suspend-idle-sandboxes.md) and wakes
on the next `session/prompt`. `BUZZ_ACP_AGENTS` is set low (the desktop's pool
of 10 is a desktop assumption). This is the capability that makes a Buzz agent
outlive the laptop, and it requires **no new Nostr code** — `buzz-acp` is Buzz's
own binary, hosted.

### Phase 2 — broker the reply through a Fountain-hosted signer (outbound moves)

Fountain serves `buzz_*` tools over its existing HTTP/SSE MCP seam
(`runtimes/acp.ex` already emits `{type: "http"|"sse", url}` MCP entries in
`session/new`), holding the nsec **server-side**. Each publish becomes a tool
call the PDP (0016) can allow/deny/escalate and the audit trail records. The
base prompt is overridden (`BUZZ_ACP_BASE_PROMPT_FILE`, ours to set once we host
`buzz-acp`) to tell the model to use the tools instead of the CLI. Scope is
deliberately partial: start with `messages send/get/thread`, `reactions add`,
`mem get/set`, and keep CLI-in-sandbox for the long tail of ~22 command groups.
The key never enters the sandbox; the sandbox no longer installs the CLI for the
brokered subset.

### Phase 3 (optional) — answer Buzz's provider protocol as `buzz-backend-fountain`

Buzz's remote-agents design (merged in block/buzz#4289) lets its desktop
discover a provider binary `buzz-backend-<id>` and hand it a one-shot `deploy`
(protocol_version 1, JSON over stdio, no management channel afterwards). A
`buzz-backend-fountain` in `cli/` would let a Buzz user "Start" a
Fountain-hosted agent from the desktop: `deploy` hands Fountain the nsec + auth
tag, Fountain stores them in a vault and starts the Phase 1 supervisor; the
returned `agent_id` is Fountain's; converge = "is a hosted `buzz-acp` already
running for this pubkey?". This is a *door*, not the architecture — it is how
Buzz's UI reaches Phase 1, and it is explicitly last because Phases 1–2 stand
without it.

## Consequences

- **A Buzz agent's identity and presence become Fountain-native state.** The nsec
  lives in a vault, decrypted only server-side; the sandbox holds neither key nor
  relay connection for the brokered path. This is the 0019 inversion applied to
  Nostr: the sandbox becomes untrusted with respect to the agent's identity.
- **Every Buzz publish becomes governable.** Phase 2 routes replies through the
  PDP and the audit trail — the first time Fountain can see and gate what an
  agent says on Nostr, not just what it ran.
- **We inherit Buzz's protocol quirks and must not fight them.** `buzz-acp`
  auto-answers `session/request_permission` by selecting the `allow_once` option
  — Buzz-the-client is never a human escalation surface, so any human approval
  for Buzz-driven turns is Fountain's (0016 gate 3 / #643) or goes to the Buzz
  owner over the relay. `buzz-acp` sends its whole system prompt as prompt
  content every turn and calls `session/set_model` (we answer method-not-found;
  non-fatal). These are load-bearing givens, not bugs to file.
- **We take on running someone else's long-lived binary.** The supervisor owns
  `buzz-acp`'s lifecycle, crashes, upgrades, and the amd64/version pinning that
  the desktop currently owns. This is real operational surface Phase 1 adds.
- **We are strictly better than Buzz's k8s binding on reaping.** That binding
  admits its inactivity reaper runs inside the body it must end and needs an
  external TTL backstop; Fountain's `Lifecycle` already is that backstop, so
  `inactivity_seconds: 0` (Buzz's blessed "indefinite") is safe for us to honour.
- **What we give up by not doing Phase 3 first:** Buzz-desktop users can't
  one-click a Fountain-hosted agent until it exists. Acceptable — Phases 1–2 are
  drivable by Fountain's own config in the meantime.

## Alternatives considered

- **Leave it as it is (CLI + key in the sandbox).** Rejected: the four costs
  above, chiefly the identity key sitting in reach of untrusted model output and
  every publish bypassing governance.
- **Broker the signature at network egress, like 0019 does for API keys.**
  Impossible, not merely rejected: a Nostr event is signed over its own content;
  there is no bearer value to swap at the proxy. Recorded here so no one
  re-proposes it.
- **Be a k8s-shaped provider (Phase 3 as the *whole* integration).** Rejected as
  the architecture: a `deploy` that provisions a sandbox running
  `buzz-acp`+harness+CLI+key puts *more* Nostr in the sandbox and bypasses Peer,
  `log_events` and the PDP — Fountain reduced to a launcher. Kept only as an
  optional door onto Phase 1.
- **Add a non-stdio ACP transport so the harness and runtime can be split over a
  network.** Rejected for v1: Buzz's ACP is stdio-only and there is no seam to
  plug a socket into; hosting the whole `buzz-acp` process is simpler and needs
  no upstream change.
- **Upstream a remote-signer (NIP-46) mode into `buzz-cli`.** Not rejected —
  noted as the cleanest long-term form of Phase 2, and Buzz's own NIP-AB doc
  already points at NIP-46 for ongoing delegation. Out of scope for the first
  cut because it requires an upstream change we don't control.

## Gates

1. **Phase 1 spike (done, 2026-08-15).** `buzz-acp` off the desktop drives
   `fountain acp` end-to-end; inbound proven live, the outbound gap measured.
2. **Phase 1 supervisor.** A Fountain-managed process that starts/stops/heals a
   `buzz-acp` per (agent × identity) from vault-held env, with presence surviving
   sandbox suspend. Owns pinning and the amd64 constraint. *Decided 2026-08-16:
   lives **inside the Fountain OTP app** (DynamicSupervisor + per-identity
   GenServer running `buzz-acp` as a Port), not a separate sidecar.*
3. **Phase 2 signer.** HTTP-MCP `buzz_*` tools with the key server-side, a
   base-prompt override, and PDP + audit hooks on every publish. *Decided
   2026-08-16: go straight to native tools; the interim sandbox shim is skipped.*
4. **Phase 3 provider (optional).** `buzz-backend-fountain` in `cli/` mapping
   Buzz's `deploy` onto the Phase 1 supervisor; conforms to block/buzz's
   remote-agents [L1]/[L2] checklist and documents its own binding.
