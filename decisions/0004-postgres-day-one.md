---
type: ADR
title: "Postgres from day one (drop the SQLite path)"
description: "Managed Postgres is the only relational store from launch; the SQLite/Litestream path is dropped. UUID v7 primary keys were never built (2026-08-02 addendum)."
tags: [data, infra]
status: stable
adr: "0004"
adr_status: "Accepted"
date: 2026-05-09
generated: { by: human:jhgaylor, at: 2026-08-02T23:13:41-04:00 }
verified: { by: human:jhgaylor, at: 2026-08-02T23:13:41-04:00 }
---

# 0004 — Postgres from day one (drop the SQLite path)

**Status:** Accepted — 2026-05-09.

## Context

The Phase 2 engineering plan (`plan/phase-2-build-plan/engineering-plan.md`) raised OQ-1b: SQLite + WAL on a Render persistent disk for launch, or Postgres? The plan's working assumption was SQLite, justified by aod-ex's existing use of it and by the modest scale of the 100-WAU success metric. Postgres was framed as a later cutover.

Two facts pushed the decision the other way at G2:

1. **The cutover has a real cost and risk profile.** A SQLite→Postgres migration mid-product means coordinating a downtime window, validating data parity, and reworking infra (replace persistent disk, add managed Postgres, swap `DATABASE_URL`, retest backups). Done well it's a sprint; done badly it's an incident. Doing it once, at G2, while the schema is still ink-on-paper, removes that risk entirely.
2. **The SQLite path required Litestream for any meaningful PITR.** OQ-9b would have added Litestream + S3 to the launch infrastructure list. Managed Postgres backups are a single line of `render.yaml` configuration and a known commodity for the operator. Strictly less infrastructure to learn.

aod-ex's reference value ([ADR 0002](0002-aod-ex-as-reference.md)) is in the schema and the contexts, not the storage adapter. Ecto abstracts both backends; the migration files differ only in field types where Postgres-specific features (`jsonb`, `uuid`, `bytea`) are clearly preferable.

## Decision

Fountain ships with **managed Postgres** as its only relational store from launch. The SQLite + Litestream path described in earlier drafts of the engineering plan is removed.

Concretely:
- `render.yaml` declares a managed Postgres database, exposes `DATABASE_URL` to the web service, and removes the persistent disk that SQLite required.
- Ecto repo configured for `Ecto.Adapters.Postgres`.
- Schema definitions use `jsonb` for `metadata` columns (`usage_events`, `admin_audit_events`), `binary_id` (UUID) for primary keys, and `bigint` for the append-only event PKs.
- All new tables use UUID v7 (separate decision, OQ-1c) — the time-ordering benefit is realized on Postgres B-tree indexes specifically. *(**Never built** — primary keys are UUIDv4; see Addendum 2026-08-02.)*
- Backups: rely on Render's managed Postgres daily backups + PITR. No Litestream needed; OQ-9b is N/A. *(Superseded — see Addendum 2026-08-02.)*

## Consequences

- One less pending migration on the roadmap. Sprint 1 onward writes Postgres-native schemas directly; no abstraction layer needed to keep the SQLite option open.
- Operational floor rises slightly: a managed Postgres line item on Render replaces the cost of a small persistent disk. Within tolerance for the launch budget.
- Schema and query review can use Postgres-specific features without restraint — `jsonb` operators, partial indexes, `GENERATED ALWAYS AS IDENTITY`, etc. — when they pay for themselves.
- If a future product line truly needs an embedded single-tenant deployment (a Fountain Lite distributed as a single binary), that's a separate product with its own storage decision; this ADR does not constrain that.
- Reversal cost: low at G2 (no production data exists). Once production data exists, reversing this is a Postgres→SQLite migration, which is materially worse than the cutover this ADR avoids. Treat as effectively irreversible after launch.

## Alternatives considered

- **SQLite + Litestream at launch, Postgres cutover later.** The original engineering-plan default. Rejected: pushes a known migration into a future sprint, requires Litestream tuning the operator hasn't done before, and saves only the cost of a managed Postgres line item — not enough to justify the future-toil debt.
- **SQLite at launch, no Litestream, accept the backup gap.** Rejected: Render persistent disks are not cross-AZ replicated; a disk failure would lose data between snapshots. Unacceptable for a paid product (G2 chose a hard billing gate, [ADR 0006](0006-hard-stripe-billing-gate-at-launch.md)).
- **Postgres-compatible managed serverless (Neon, Supabase) instead of Render-managed Postgres.** Rejected for launch: adds a vendor relationship and egress considerations that aren't justified before there's evidence Render's managed Postgres is the bottleneck. Easy to revisit if it becomes one.

## Addendum — 2026-08-02

Two claims above no longer match (or never matched) the code:

- **UUID v7 was never built.** Every schema uses `@primary_key {:id, :binary_id, autogenerate: true}` (e.g. `apps/fountain/lib/fountain/accounts/user.ex`), which generates `Ecto.UUID` values — **UUIDv4**. No v7 library is in the dependency tree. The B-tree time-ordering benefit claimed above therefore does not exist. If time-ordered ids become necessary, that is a new decision (and a migration), not something this ADR delivered.
- **Backups are no longer Render's.** Production Postgres is CloudNativePG on the home-cloud Kubernetes cluster; backups are handled by `k8s/backup-cronjob.yaml`, `k8s/objectstore.yaml`, and `k8s/scheduledbackup.yaml`. The "Render managed backups + PITR" line is superseded. The core decision (Postgres from day one, no SQLite path) stands and is unaffected.
