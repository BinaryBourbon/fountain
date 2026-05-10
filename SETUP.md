# Local workstation setup

Bootstrap a fresh machine (laptop, ephemeral VM, codespace) to run, test, and deploy Fountain. Should take ~10 minutes on broadband.

## Prerequisites

| Tool       | Why                                                                 | Install                                                                 |
| ---------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `mise`     | Pins Elixir/Erlang to the exact versions in `.tool-versions`.       | `brew install mise` (macOS) · `curl https://mise.run \| sh` (Linux/WSL) |
| `gh`       | GitHub CLI for cloning and PRs.                                     | `brew install gh && gh auth login`                                      |
| `psql`     | Client for the dev/test Postgres.                                   | Comes with `brew install postgresql@16` (or any 14+).                   |
| Docker *or* native Postgres 14+ | One way to host the dev/test database.                  | `brew install --cask orbstack` (or Docker Desktop), or `brew install postgresql@16 && brew services start postgresql@16`. |

After installing `mise`, [activate it in your shell](https://mise.jdx.dev/getting-started.html#activate-mise):

```bash
# zsh
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc

# bash
echo 'eval "$(mise activate bash)"' >> ~/.bashrc
```

Open a new shell so `mise` is on the PATH.

## 1. Clone

```bash
gh repo clone BinaryBourbon/fountain
cd fountain
```

## 2. Install the toolchain

```bash
mise install
```

This reads `.tool-versions` and installs the pinned Erlang/OTP and Elixir versions (~5 min on first run, cached after). The same `.tool-versions` is what Render uses in production, so dev and prod stay in lockstep.

Verify:

```bash
elixir --version
# Erlang/OTP 28 ...
# Elixir 1.19.2 (compiled with Erlang/OTP 28)
```

## 3. Hex + Rebar (one-time, per-toolchain)

```bash
mix local.hex --force
mix local.rebar --force
```

## 4. Postgres

Pick **one** path:

### Option A — Docker (recommended for ephemeral machines)

```bash
docker compose up -d postgres
```

Brings up Postgres 16 on `localhost:5432` with role `postgres`/`postgres` and database `fountain_dev`. Stop with `docker compose down`; data persists in the `postgres_data` volume.

### Option B — Native Postgres

If you already run Postgres locally (e.g. `brew services start postgresql@16`), make sure a `postgres` superuser role exists with password `postgres`:

```bash
psql -h localhost -U "$USER" -d postgres \
  -c "CREATE ROLE postgres WITH LOGIN SUPERUSER PASSWORD 'postgres'"
```

(Skip if you already have it.)

Both paths satisfy the default `DATABASE_URL` baked into `config/dev.exs` and `config/test.exs`. To override, export `DATABASE_URL` before any `mix` command.

## 5. Dependencies and database

```bash
mix deps.get
mix setup        # deps.get + ecto.setup for the dev DB
```

For the test DB:

```bash
MIX_ENV=test mix ecto.create
MIX_ENV=test mix ecto.migrate
```

## 6. Run

```bash
mix phx.server   # http://localhost:4000
mix test         # full suite
```

`mix precommit` runs the same checks CI does (warnings-as-errors, format, credo, tests).

## Production parity reference

`render.yaml` and `.tool-versions` are kept aligned. If you bump the toolchain, change both:

| Where           | Erlang/OTP | Elixir        |
| --------------- | ---------- | ------------- |
| `.tool-versions`| `28.3`     | `1.19.2-otp-28` |
| `render.yaml`   | `28.3`     | `1.19.2`      |

## Troubleshooting

- **`role "postgres" does not exist`** — see step 4. Either `docker compose up -d postgres` or create the native role.
- **Compile warnings about `OpentelemetryPhoenix` / `OpentelemetryEcto`** — these deps are `:prod`-only; `apply/3` is used to defer symbol resolution. If you see warnings, you're probably on stale `_build`; `rm -rf _build deps && mix deps.get && mix compile` to reset.
- **mise installs Erlang from source and it's slow** — that's normal on first run. Subsequent installs (and ephemeral machines that share a mise cache) reuse the build.
- **Tests fail with `rate_limited` errors** — `FountainWeb.Plugs.RateLimit` shares an ETS table across the suite; run `mix test --seed 0` or isolate the failing file.
