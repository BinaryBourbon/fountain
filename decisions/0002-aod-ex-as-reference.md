# 0002 — `jhgaylor/aod-ex` is the reference implementation Fountain forks from

**Status:** Accepted — 2026-05-09.

## Context

[`jhgaylor/aod-ex`](https://github.com/jhgaylor/aod-ex) is a working single-tenant implementation of the capability set Fountain needs: managing agents, repos, secrets, conversations, MCP servers, and skill setups for sandboxed coding-agent instances. It exists, it runs, and the maintainer (jhgaylor) is the same person driving Fountain.

Fountain's reason for existing is not that aod-ex's capabilities are wrong. It's that aod-ex targets a different user (single-operator, local) and rebuilding around a multi-tenant API/UI for external users requires a different shape — auth, isolation, billing surface, onboarding UX, debugging affordances — even when the underlying primitives stay the same.

Without a written marker, future specialists (especially customer-researcher in `phase-0-framing` and engineers later) risk re-deriving the capability set from scratch, missing prior art, or rebuilding decisions aod-ex already made well.

## Decision

Treat `jhgaylor/aod-ex` as Fountain's **reference implementation**. Specialists doing framing, design, or engineering work on Fountain should:

1. Read aod-ex's code and docs before proposing scope or architecture for an equivalent capability.
2. Default to preserving aod-ex's primitives (agents, repos, secrets, conversations, MCP/skill config) unless there's a multi-tenancy reason to change them.
3. Make the *delta* the focus of design discussion — what has to change for multi-tenant, multi-user, API-first use — rather than re-litigating the single-tenant baseline.

This is **not** a license to copy code wholesale. Fountain is a new repo with a new architecture; aod-ex is the spec, not the substrate.

## Consequences

- `phase-0-framing` and subsequent slices have a concrete starting point, reducing wasted exploration.
- Decisions that diverge from aod-ex should be captured as ADRs (e.g. "0003 — drop aod-ex's X because multi-tenant requires Y") so the lineage stays traceable.
- If aod-ex evolves materially after Fountain forks conceptually, this ADR may need a refresh — flag it at the next gate review.
- Implicit dependency on aod-ex remaining accessible to the team. If that changes (private, deleted, abandoned), this ADR loses force.

## Alternatives considered

- **Treat Fountain as a clean-sheet design.** Rejected — discards working prior art and forces re-derivation of capabilities the operator already validated single-tenant.
- **Fork aod-ex directly and refactor toward multi-tenant.** Rejected — aod-ex's shape is tuned for a different user; bolting multi-tenancy onto it tends to produce worse outcomes than rebuilding around the new shape with aod-ex as a reference.
- **Leave the relationship implicit (status quo before this ADR).** Rejected — captain-picard dispatches read these files cold and need the lineage made explicit, not buried in a description paragraph.
