## Context

G2 locked. Build starts now. The full engineering plan is at `plan/phase-2-build-plan/engineering-plan.md`. Three load-bearing ADRs are now in `decisions/`: 0004 (Postgres), 0005 (Sprites token), 0006 (Stripe billing gate). Read all three and the engineering plan before writing any code.

Your slice is the **foundation**: copy the aod-ex codebase into this repo, rename all modules to the Fountain namespace, wire Postgres in place of SQLite, write all new migrations, and implement the new schemas and Accounts context. A parallel slice (`phase-3-tenant-contexts`) is running at the same time and will refactor the existing aod-ex context modules; you own everything in `lib/fountain/accounts/`, `lib/fountain/crypto.ex`, and `priv/repo/migrations/`. Do not touch the existing aod-ex context modules (environments, agents, vaults, conversations) — that is the other slice’s scope.

## Task

- Copy `jhgaylor/aod-ex` source into `BinaryBourbon/fountain` on a new branch `phase-3-foundation`. Preserve the umbrella structure.
- Rename all modules: `AgentOnDemand` → `Fountain`, `AgentOnDemandWeb` → `FountainWeb`, `AodCli` → `FountainCli`. Update `mix.exs` app names accordingly.
- Swap SQLite for Postgres: remove `ecto_sqlite3`, add `postgrex`. Update `config/dev.exs` and `config/test.exs` to use `DATABASE_URL` / local Postgres. Add a `docker-compose.yml` with a `postgres:16` service for local dev. Update `render.yaml` per the engineering plan §9.1 (remove `ADMIN_TOKEN`, `SECRETS_KEY`, add `MASTER_SECRETS_KEY`, `DATABASE_URL`, etc.).
- Write migrations for all **new** tables in this order (do not alter existing aod-ex migrations):
  1. `users` — per §1.1
  2. `oauth_identities` — per §2.4
  3. `api_keys` — per §1.1
  4. `user_data_keys` — per §1.1
  5. `usage_events` — per §1.1
  6. `admin_audit_events` — per §3.5
  7. Add `user_id` FK columns to: `environments`, `agents`, `vaults`, `conversations`, `sandboxes` — per §1.2. Also update unique indexes on `environments.name`, `agents.name`, `vaults.name` to be `(user_id, name)` per §1.2.
- Implement `Fountain.Crypto`: replace the single-key AES-256-GCM from aod-ex with envelope encryption per §1.3. `encrypt/3` and `decrypt/3` accept a `key` argument (32-byte binary). Add `load_tenant_key/1` (unwraps DEK from `user_data_keys` using `MASTER_SECRETS_KEY` from `Application.fetch_env!`).
- Implement `Fountain.Accounts` context + schemas: `User`, `ApiKey`, `UserDataKey`, `OauthIdentity`. Include changesets, basic CRUD functions (`get_user_by_email/1`, `register_user/1`, `create_api_key/2`, `revoke_api_key/2`, `get_user_by_api_key/1`). `get_user_by_api_key/1` must hash the raw key with SHA-256 before querying `api_keys.key_hash`.
- Add required deps to `mix.exs`: `bcrypt_elixir` (password hashing), `uniq` (UUID v7), `stripity_stripe`, `swoosh`, `gen_smtp`, `ueberauth`, `ueberauth_github`.

## Acceptance

- PR `phase-3-foundation` against `main` on `BinaryBourbon/fountain`.
- `mix compile` passes with no errors after the rename.
- All 7 migration groups exist and are syntactically valid Ecto migrations.
- `Fountain.Crypto.load_tenant_key/1`, `encrypt/3`, `decrypt/3` are implemented and unit-tested.
- `Fountain.Accounts` context functions are implemented with basic unit tests (no DB required for pure functions; DB tests use the test Postgres).
- `render.yaml` reflects all env-var changes from §9.1.
- `docker-compose.yml` boots a Postgres 16 container.

## Out of scope

- Do not implement auth plugs, controllers, or LiveViews — that is `phase-3-auth`.
- Do not refactor existing aod-ex context modules (environments, agents, vaults, conversations) — that is `phase-3-tenant-contexts`.
- Do not implement billing logic, quota checks, or Stripe integration beyond adding the `stripity_stripe` dep.
- Do not remove the `aod up` / `aod down` CLI subcommands yet — leave them in place; the CLI slice will remove them.
