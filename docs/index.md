# Fountain

Fountain is a **multi-tenant API** for managing agents, repos, secrets, and conversations, with an operator console over it and standalone apps for watching an agent work. It's for people who want to create sandboxed coding agent instances with preconfigured sets of env vars, MCP servers, skills, repos, and packages.

!!! tip "In a hurry?"
    Install the CLI and point it at a Fountain instance:
    ```sh
    brew install BinaryBourbon/tap/fountain
    fountain auth login
    fountain apply -f agent-specs
    ```

## Why Fountain?

Running Claude instances with worktrees locally and shuffling MCP configurations and skill setups by hand is painful. [`jhgaylor/aod-ex`](https://github.com/jhgaylor/aod-ex) solves this for a single tenant; Fountain takes that core and rebuilds it around multi-tenant use.

## The four primitives

| Primitive | What it is |
|---|---|
| [**Environment**](primitives.md#environment) | Baseline set of encrypted env vars + runtime config |
| [**Vault**](primitives.md#vault) | Free-floating bag of env-var overrides that layer on top of an environment |
| [**Agent**](primitives.md#agent) | A named, re-runnable agent config with model, skills, MCP servers |
| [**Conversation**](primitives.md#conversation) | A single run of an agent inside a sandboxed VM with streaming logs |

## Get started

- [**Local setup**](setup.md) - bootstrap a workstation in ~10 minutes
- [**Architecture**](architecture.md) - what runs, what it talks to, what breaks when a dependency is down
- [**Primitives deep-dive**](primitives.md) - understand the data model
- [**CLI reference**](cli.md) - `fountain` command surface
- [**API reference**](api.md) - REST endpoints and auth
- [**LLM integration**](llm-integration.md) - connect any agentic IDE via `/skill`
- [**Plugging into Fountain**](integrations/clients.md) - editors, chat surfaces, plugins, SDKs
- [**Services Fountain uses**](integrations/index.md) - what an operator configures: sandboxes, mail, OAuth, billing, errors
