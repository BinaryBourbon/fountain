# Local setup

Bootstrap a fresh machine (laptop, ephemeral VM, codespace) to run, test, and deploy Fountain. Should take ~10 minutes on broadband.

## Prerequisites

| Tool | Why | Install |
|---|---|---|
| `mise` | Pins Elixir/Erlang to exact versions in `.tool-versions` | `brew install mise` (macOS) or `curl https://mise.run | sh` (Linux/WSL) |
| `gh` | GitHub CLI for cloning and PRs | `brew install gh && gh auth login` |
| `psql` | Client for dev/test Postgres | Comes with `brew install postgresql@16` |
| Docker or native Postgres 14+ | Host the dev/test database | `brew install --cask orbstack` or `brew install postgresql@16` |

After installing `mise`, [activate it in your shell](https://mise.jdx.dev/getting-started.html#activate-mise).

## 1. Clone

```bash
gh repo clone BinaryBourbon/fountain
cd fountain
```

## 2. Install the toolchain

```bash
mise install
```

Reads `.tool-versions` and installs Erlang/OTP 28 + Elixir 1.19.2. The same pinned versions are used in production.

Verify:

```bash
elixir --version
# Erlang/OTP 28 ...
# Elixir 1.19.2 (compiled with Erlang/OTP 28)
```

## 3. Hex + Rebar (one-time per toolchain)

```bash
mix local.hex --force
mix local.rebar --force
```

## 4. Postgres

**Option A - Docker (recommended):**

```bash
docker compose up -d postgres
```

Brings up Postgres 16 on `localhost:5432`. Stop with `docker compose down`; data persists in the `postgres_data` volume.

**Option B - Native Postgres:**

```bash
psql -h localhost -U "$USER" -d postgres \
  -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres'"
```

Both satisfy the default `DATABASE_URL` in `config/dev.exs` and `config/test.exs`.

## 5. Dependencies and database

```bash
mix deps.get
mix setup                           # dev DB: create + migrate
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

## 6. Environment variables

Copy `.env.example` to `.env` and fill in the blanks:

```bash
cp .env.example .env
```

| Variable | Purpose |
|---|---|
| `DATABASE_URL` | Postgres connection |
| `MASTER_SECRETS_KEY` | Platform master key for envelope encryption |
| `SPRITES_TOKEN` | Sprites sandbox platform token |
| `GITHUB_OAUTH_CLIENT_ID/SECRET` | GitHub OAuth app |
| `STRIPE_*` | Billing integration |
| `RESEND_API_KEY` | Transactional email |

Generate a master key:

```bash
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '='
```

## 7. Run

```bash
mix phx.server   # http://localhost:4000
mix test         # full test suite
mix precommit    # same checks CI runs
```

## Troubleshooting

- **`role "postgres" does not exist`** - See step 4.
- **Tests fail with connection pool timeouts** - Make sure `config/test.exs` has `pool_size: 20`.
- **`mise` is slow on first run** - Normal; it compiles Erlang from source (~5 min). Cached after.
