# 0009 — Token-only sandboxes: secret values stop entering the sprite

**Status:** Proposed — drafted 2026-08-02 for the decision requested in #148.
Nothing below is committed until this ADR is accepted.

## Context

Sandboxes run untrusted code on purpose. The honest threat model (#148) is
that everything readable inside a sprite is exfiltrated the moment the agent
starts — prompt injection is enough; no exploit required. Today the
environment+vault merge materializes every secret as a plaintext env var at
spawn, including `${VAR}` substitution into MCP server configs.

What already exists bounds the damage without removing the exposure:

- Write-only secret storage and envelope encryption at rest.
- Per-conversation `FOUNTAIN_TOKEN` scoped to its owner (#75), callback-token
  scoping and key expiry (#206), agent-scoped vault allowlists (#144).
- Output redaction (#222) — which its own author documents as bounded: it only
  matches values it knows, so a derived secret (base64d, split, reshaped)
  passes through, and there is an 8-byte floor. Both limits vanish only if
  values never enter the sprite at all.

#148 proposes the model: the sprite holds exactly one credential — the
conversation token — and secret values resolve *outside* the boundary, via
(a) egress credential injection for HTTP-auth secrets and (b) a broker
exchange for the rest, with environments declaring `{key, reference}` instead
of `{key, value}`.

Since #148 was filed, the egress-injection half stopped being something we
would have to build. **[Infisical agent-vault]** is an open-source (Go, MIT,
~2k stars) credential proxy purpose-built for exactly this: agents route
outbound HTTPS through it (`HTTPS_PROXY` + MITM CA), it substitutes dummy
values (`__github_pat__`) with real credentials on the way out, filters
egress (`unmatched_host_policy=deny`), supports multi-tenant vaults, and its
documented "secure ephemeral sandboxes" pattern — orchestrator mints a
temporary token, passes it into the sandbox, sandbox proxies through the
vault — is Fountain's architecture described from the other side. Its
commercial sibling (Infisical Agent Proxy) is built into Infisical, which
this deployment already runs for secret materialization.

## Decision (proposed)

Adopt the token-only direction, with the injection layer **operated, not
built**:

1. **Phase 0 — name the exposure (no behavior change).** Add per-secret
   `exposure: value | injected | brokered`, defaulting to `value` (today's
   behavior). Immediately makes "a value enters the sandbox" a greppable,
   reviewable declaration, and gives the API the vocabulary the later phases
   need. Ship independently of everything below.
2. **Phase 1 — egress injection via agent-vault.** Run an agent-vault (or
   Agent Proxy) instance reachable from sprites; at spawn, mint a
   per-conversation vault token, set `HTTPS_PROXY` + trust its CA in the
   sprite env, and register the conversation's `exposure: injected` secrets
   as substitution rules scoped to that token. Revoke at terminate, alongside
   the existing token revocation. `networking_type: limited` folds in
   naturally — the proxy's service rules and the allowlist are the same
   object, which also answers the question #228 died on.
3. **Phase 2 — broker exchange** for non-HTTP secrets, using the existing
   conversation token against a Fountain endpoint that returns short-lived
   derivatives. The write-only storage is already the storage half.
4. **Phase 3 — references, not values, in the API** (`{key, provider/scope}`),
   turning vaults into reference bundles. The largest surface change; gated on
   the earlier phases proving out.

## Consequences

- The worst case for an injected secret drops from "exfiltrated" to "agent
  used the credential for an unauthorized request through a logged, filtered
  proxy" — visible, revocable, and scoped.
- A new operated dependency with real availability coupling: if the proxy is
  down, conversations whose secrets are `injected` cannot reach their
  upstreams. It must not run as a single point on the same failure domain as
  the thing it unblocks (same reasoning that put error tracking off-cluster
  in #211 — but here the sprite must *reach* it, so it is on the serving
  path).
- MITM CA trust must be bootstrapped into every runtime's HTTP stack
  (`NODE_EXTRA_CA_CERTS`, `SSL_CERT_FILE`, git, curl…) — provisioning already
  owns sprite env, but tool coverage will be a long tail.
- `exposure: value` remains for things that genuinely need in-process values
  (`DATABASE_URL`); the default flipping from `value` to safer modes would be
  a breaking change and gets its own decision later.
- Self-hosters get this as opt-in (an agent-vault service in the compose
  file), never as a requirement.

## Alternatives considered

- **Build egress injection into the Sprites layer** — requires platform
  capabilities Sprites has not established (the domain-allowlist ↔ SSH
  question from #228 was this same unknown); building it app-side via a proxy
  works with Sprites as-is.
- **Build our own broker/proxy** — duplicates a funded, active OSS project
  whose scope is exactly this; the differentiating work for Fountain is the
  orchestration (mint/revoke/scope per conversation), not TLS interception.
- **Redaction only (status quo)** — already shipped, already documented as
  insufficient by its author (#222): derived secrets pass through.
- **Infisical Agent Proxy instead of agent-vault** — stays open as a variant
  of the same decision: same model, deeper coupling to the Infisical instance
  already deployed. Choosing between them is an operational call inside
  Phase 1, not a different architecture.

## Open questions for the decision

1. Accept the phased direction? (Phase 0 is cheap and useful even if the rest
   waits.)
2. agent-vault (self-contained binary) vs Infisical Agent Proxy (inside the
   Infisical already running) for Phase 1?
3. Where does the proxy live — home cluster behind the existing ingress, or
   somewhere off-cluster — given sprites must reach it from sprites.dev and
   it sits on the conversation serving path?
4. Does @lex00's offer to prototype the egress path still stand, and against
   agent-vault rather than spritzer?

[Infisical agent-vault]: https://github.com/Infisical/agent-vault
