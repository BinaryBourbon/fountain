# Fountain

A multi-tenant API and UI for managing agents, repos, secrets, and conversations. It's for people who want to create sandboxed coding agent instances with preconfigured sets of env vars, MCP servers, skills, repos, and packages. Users treat Fountain as a building block for their own workflows, but also use the UI to get started and to debug. It exists because running Claude instances with worktrees locally — and shuffling MCP configurations and skill setups by hand — is painful. `jhgaylor/aod-ex` already does this for a single tenant, but it targets a different user; Fountain takes that core and rebuilds around multi-tenant use.

This repo is the bus for the [`captain-picard`](https://github.com/jhgaylor/aod-specs) Agent on Demand orchestrator. See `OPERATING_MODEL.md` for how the team operates and `ROADMAP.md` for what's open.

## Get started with the CLI

Install the `fountain` binary from the [Homebrew tap](https://github.com/BinaryBourbon/homebrew-tap):

```sh
brew install BinaryBourbon/tap/fountain
```

Log in against your Fountain instance — prompts for email + password, writes `~/.fountain/credentials`:

```sh
fountain auth login
```

Apply a manifest. [`jhgaylor/agent-specs`](https://github.com/jhgaylor/agent-specs) is a public example tree of agents, environments, and vaults:

```sh
git clone https://github.com/jhgaylor/agent-specs
fountain apply -f agent-specs
```

`fountain apply` walks the directory and applies every `*.yml` / `*.yaml` doc that declares both `apiVersion` and `kind`. See [`cli/README.md`](cli/README.md) for the rest of the command surface.

## Bootstrap a workstation

See [`SETUP.md`](SETUP.md) for the full local bootstrap (mise + Postgres + deps). The toolchain version is pinned in `.tool-versions` and mirrored in `render.yaml`, so a fresh laptop or ephemeral VM gets the same Erlang/Elixir as production.
