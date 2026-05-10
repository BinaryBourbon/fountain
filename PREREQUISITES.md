# Prerequisites

This template is the *bus repo*. To run the [`captain-picard`](https://github.com/jhgaylor/aod-specs/blob/main/agents/teams/captain-picard/captain-picard.yml) agent against it, you also need the agent itself provisioned in your Agent on Demand instance, plus the CLIs that talk to AoD and to your secret store.

You only do this once per machine (or once per AoD instance). After that, every new product just clicks "Use this template" and runs `/bootstrap`.

## What you need running

- An **Agent on Demand** server you can talk to. Local dev (`aod up`) or a hosted instance — either works. You need its base URL and an API token. See [`ravi-hq/agent-on-demand-ex`](https://github.com/ravi-hq/agent-on-demand-ex) if you're standing one up from scratch.
- An **Infisical** project for resolving the secrets `aod-specs` references. The `aod-specs/.infisical.json` binds the repo to the right project; you just need to be logged in.

## One-time setup

### 1. Install the CLIs

```bash
# GitHub CLI — used to fetch the aod binary release.
brew install gh && gh auth login

# Infisical CLI — used to resolve secrets at apply-time.
brew install infisical/get-cli/infisical && infisical login
```

### 2. Clone aod-specs and install the aod CLI

```bash
git clone https://github.com/jhgaylor/aod-specs.git
cd aod-specs
make install        # downloads the aod binary to ~/.local/bin/aod
```

Make sure `~/.local/bin` is on your `$PATH`. Verify with `aod --help`.

### 3. Apply the manifest

`make apply` reconciles every Agent / Environment / Vault in `aod-specs/` against your AoD instance. `captain-picard`, the specialist fleet, and the `product-team` env all get provisioned in this step.

```bash
# Set these for your AoD instance — make apply uses them.
export AOD_BASE_URL=http://localhost:4000   # or your hosted URL
export AOD_TOKEN=...                        # your AoD API token

make apply
```

Verify the agent registered:

```bash
aod agent list | grep captain-picard
```

If that's empty, re-read the `make apply` output — most likely an Infisical secret didn't resolve (re-`infisical login`) or your `AOD_TOKEN` is wrong.

### 4. Seed a project vault (per product owner, not per project)

The `product-team` env's baseline `GITHUB_TOKEN` is from `infisical:///dev/GITHUB_TOKEN` — typically a personal-scope token that can clone public repos but can't push to the org that owns this bus repo. So before `captain-picard` can push to your bus repo, you need an AoD vault that overrides `GITHUB_TOKEN` with one scoped to the bus-repo's owner.

If a vault already exists for that owner (e.g. you're spinning up your second product under the same GitHub org), skip this step.

Otherwise, in `aod-specs/vaults/` drop a file mirroring [`vaults/binarybourbon.yml`](https://github.com/jhgaylor/aod-specs/blob/main/vaults/binarybourbon.yml):

```yaml
---
apiVersion: aod/v1
kind: Vault
metadata:
  name: <project-vault>
spec:
  description: <Owner>'s GitHub credentials and git identity
  secrets:
    GITHUB_TOKEN: infisical:///dev/<OWNER>_GITHUB_TOKEN
    GIT_AUTHOR_NAME: <Owner>
    GIT_AUTHOR_EMAIL: <id+owner>@users.noreply.github.com
    GIT_COMMITTER_NAME: <Owner>
    GIT_COMMITTER_EMAIL: <id+owner>@users.noreply.github.com
```

Add the matching `<OWNER>_GITHUB_TOKEN` secret in Infisical (a write-scoped PAT for that owner), then re-run `make apply`. Confirm with `aod vault list | grep <project-vault>`.

You'll pass `<project-vault>` to both the `--vault` flag and the `vault_name=` line when invoking captain-picard. See [`aod-specs/OPERATIONS.md`](https://github.com/jhgaylor/aod-specs/blob/main/OPERATIONS.md#running-the-project-agnostic-team) for the full operator runbook.

## When something doesn't work

- **`aod agent list` is empty after `make apply`.** Either Infisical isn't logged in, `AOD_TOKEN` is wrong, or the AoD server isn't reachable at `AOD_BASE_URL`. Run `aod agent list` directly (without `make`) to see the raw error.
- **`captain-picard` fails on its first push with `Permission denied`.** The vault wasn't passed (`--vault <project-vault>`), or the vault's `GITHUB_TOKEN` doesn't have write access to the bus repo. Re-check both.
- **Infisical secret resolution errors during `make apply`.** Your `infisical login` session has expired — log in again.

After all of this works once, you don't think about prerequisites again. Bootstrapping each new product is just: click "Use this template" → clone → `claude` → `/bootstrap`.
