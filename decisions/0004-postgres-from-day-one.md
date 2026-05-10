# 0004 — Postgres from day one (no SQLite path)

**Status:** Accepted — 2026-05-10.

## Context

`jhgaylor/aod-ex` uses SQLite on a persistent disk, with Litestream as a backup strategy. The engineering plan (G2) identified switching to Postgres as the first significant infrastructure decision for Fountain because the multi-tenant data model (per-tenant encryption keys, usage events, billing records, admin audit logs) needs robust concurrent writes and native `jsonb` for metadata columns.

## Decision

Fountain uses **Postgres from day one**. There is no SQLite path and no planned SQLite→Postgres migration. Specifically:

- `render.yaml` provisions a managed Postgres service rather than a persistent disk.
- `DATABASE_URL` (Postgres connection string) is the only supported database env var.
- Ecto's `Repo` is configured for `Ecto.Adapters.Postgres` in all environments (dev uses a local Postgres instance or `docker compose`, test uses a test DB).
- Litestream is not installed or configured.
- The `mix.exs` `ecto_sqlite3` dependency is removed; `postgrex` is added.
- `jsonb` is used for all `metadata` map columns in `usage_events` and `admin_audit_events`.
- UUID v7 PKs (via `Uniq.UUID` or equivalent) are used on all new tables for B-tree index locality.

## Consequences

- Local development requires a running Postgres instance. A `docker-compose.yml` with a `postgres:16` service is the recommended dev setup; `mix setup` will document this.
- The Render managed Postgres bill is a new operating cost. At launch scale (100 WAU), a Render Starter Postgres instance is sufficient.
- Removes the SQLite→Postgres cutover from the roadmap entirely — a sprint that would otherwise have been required.
- Any future decisions that reference "SQLite" or "persistent disk" from aod-ex docs are superseded by this ADR.

## Alternatives considered

- **SQLite at launch, Postgres later** — Rejected. Delays the cutover cost to a worse time (when live user data must be migrated), and SQLite’s concurrent-write model is unsuitable for multi-tenant workloads.
- **PlanetScale / Neon / Supabase managed Postgres** — Deferred. Render managed Postgres is sufficient at launch and avoids a third-party dependency. Revisit if cost or performance requires it post-launch.
