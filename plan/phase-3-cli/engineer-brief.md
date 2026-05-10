## Context

The foundation slice renamed the umbrella from aod-ex to Fountain. The full engineering plan is at `plan/phase-2-build-plan/engineering-plan.md` (§7 CLI Distribution). Read it before writing any code. The UX spec at `plan/phase-2-build-plan/ux-spec.md` §5a describes the API key format the CLI must support.

This slice is entirely within `apps/fountain_cli/` (previously `apps/aod_cli/`). A parallel slice (`phase-3-auth`) is running at the same time but touches only the Phoenix app — no overlap. The auth endpoints this CLI calls (`POST /api/auth/token`, `GET /api/auth/me`, `POST /api/auth/api-keys`, `DELETE /api/auth/api-keys/:id`) are being implemented by the auth slice; write the CLI against the planned API shape.

## Task

Branch `phase-3-cli` from `main`.

- **Rename binary** from `aod` to `fountain` throughout `mix.exs` and the Burrito config.
- **Default base URL**: change compile-time default from `http://localhost:4000` to `https://fountain.dev` via `Application.compile_env(:fountain_cli, :base_url, "https://fountain.dev")`.
- **Auth env var**: rename `AOD_TOKEN` → `FOUNTAIN_API_KEY`. Update all references in `lib/fountain_cli/api.ex` and subcommand modules.
- **Credentials file** per §7.4: implement `FountainCli.Credentials` — read/write `~/.fountain/credentials` as multi-profile TOML. Profile selection precedence: `--profile <name>` flag > `FOUNTAIN_PROFILE` env > `default`. `FountainCli.Config.api_key/1` checks env var first, then credentials file.
- **New subcommands** per §7.2:
  - `fountain auth login [--profile <name>]` — prompts email + password interactively, calls `POST /api/auth/token` (session token endpoint from the auth slice), writes key to `~/.fountain/credentials`.
  - `fountain auth logout [--profile <name>]` — deletes the named profile section from the credentials file.
  - `fountain auth whoami [--profile <name>]` — calls `GET /api/auth/me`, prints email + role.
  - `fountain keys list` — calls `GET /api/auth/api-keys`, prints table (name, prefix, last used).
  - `fountain keys create <name>` — calls `POST /api/auth/api-keys`, prints plaintext key once with a prominent "Save this key — it will not be shown again" warning.
  - `fountain keys revoke <id>` — calls `DELETE /api/auth/api-keys/:id` with confirmation prompt.
- **Remove** `fountain up` / `fountain down` subcommands (aod-ex Sprites host deploy). Fountain is hosted; self-deploy is not a supported flow.
- **Preserve** all existing aod-ex subcommands (`env`, `agent`, `vault`, `conv`, `run`) — update them to use `FOUNTAIN_API_KEY` / `FOUNTAIN_BASE_URL` and the renamed module paths.
- **Build pipeline**: update `.github/workflows/release.yml` to produce `fountain-linux-x86_64` and `fountain-macos-aarch64` artifacts (Burrito + Zig). Keep the same tag-push trigger (`v*.*.*`).

## Acceptance

- PR `phase-3-cli` against `main` on `BinaryBourbon/fountain`.
- `mix compile` passes within `apps/fountain_cli/`.
- `mix test` passes (add tests for `FountainCli.Credentials` — read, write, multi-profile, env-var override).
- `fountain auth login --profile staging` writes only the `[staging]` section without altering `[default]`.
- `fountain up` / `fountain down` are absent from the compiled binary’s help output.
- `FOUNTAIN_API_KEY` env var takes precedence over credentials file in `FountainCli.Config.api_key/1`.
- Release workflow artifact names are `fountain-linux-x86_64` and `fountain-macos-aarch64`.

## Out of scope

- Do not implement any Phoenix/web changes — this slice is `apps/fountain_cli/` only.
- Do not implement `fountain import` — migration is out of scope per `decisions/0003` + engineering plan §8.
- Do not implement Homebrew tap distribution — GitHub releases only at launch (engineering plan §7.5).
