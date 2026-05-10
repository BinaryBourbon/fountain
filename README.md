# Fountain

A multi-tenant API and UI for managing agents, repos, secrets, and conversations. It's for people who want to create sandboxed coding agent instances with preconfigured sets of env vars, MCP servers, skills, repos, and packages. Users treat Fountain as a building block for their own workflows, but also use the UI to get started and to debug. It exists because running Claude instances with worktrees locally — and shuffling MCP configurations and skill setups by hand — is painful. `jhgaylor/aod-ex` already does this for a single tenant, but it targets a different user; Fountain takes that core and rebuilds around multi-tenant use.

This repo is the bus for the [`captain-picard`](https://github.com/jhgaylor/aod-specs) Agent on Demand orchestrator. See `OPERATING_MODEL.md` for how the team operates and `ROADMAP.md` for what's open.

## Bootstrap a workstation

See [`SETUP.md`](SETUP.md) for the full local bootstrap (mise + Postgres + deps). The toolchain version is pinned in `.tool-versions` and mirrored in `render.yaml`, so a fresh laptop or ephemeral VM gets the same Erlang/Elixir as production.
