# Fountain Ships: Preconfigured, Sandboxed Coding Agents for Your Whole Team

**Stop wiring up Claude instances by hand. Fountain gives teams a single place to define agent environments, swap credentials, and run sandboxed conversations — with real-time log visibility and nothing to configure locally.**

SAN FRANCISCO, May 10, 2026 — Fountain today announced the general availability of its hosted agent management platform. Engineering teams and solo developers can now spin up sandboxed AI coding agents with preconfigured environments, secrets, and skills in minutes — without touching a local `.env` file or worktree.

---

## The Problem

Running AI coding agents locally works — until it doesn't.

A developer using Claude Code in a single project can manage configuration by hand: environment variables in `.env`, MCP server configs in a local file, skills copy-pasted from a shared doc, git worktrees created fresh each session. The overhead is annoying but survivable.

At team scale, it breaks. A new teammate arrives and spends an afternoon reverse-engineering the setup. Someone's API key expires mid-sprint and nobody knows which `.env` to update. Two parallel tasks need different GitHub identities and there's no clean way to express that without maintaining separate local checkouts. A conversation stalls inside a sandbox and the only debugging tool is a raw SSE stream piped through `curl`.

The manual work doesn't decrease as teams adopt more agents — it compounds. Every new agent multiplies the configuration surface. Every parallel conversation multiplies the credential management problem. The productivity promise of AI-assisted coding erodes under the weight of keeping the plumbing consistent.

Existing tooling (`jhgaylor/aod-ex` and similar single-operator setups) solves this for one person running their own instance. It was never designed for a team sharing access, rotating credentials, or onboarding a new member without operator involvement.

---

## The Solution

Fountain is a hosted platform — REST API, browser dashboard, and CLI — for managing sandboxed coding agent instances with preconfigured Environments, Vaults, and Agents.

An operator defines an **Environment** once: the packages, repos, environment variables, MCP servers, and setup script an agent needs. They define an **Agent** once: the model, system prompt, runtime, and skills. When they want a conversation, Fountain provisions an isolated sandbox, mounts the configuration, and runs the agent. No shell scripts, no local worktree wrangling, no credentials in shell profiles.

Multiple users share one Fountain instance. Each user's resources are tenant-scoped and encrypted independently — other tenants cannot read them, and a compromised account does not expose the rest. A new team member signs up at a URL, walks through an onboarding wizard, and is running their first conversation before they've read a README.

Fountain is not an agent runtime. It is the operations layer that sits in front of one.

---

## Key Features

**Self-serve onboarding.** A new user arrives at a URL, registers, configures a first agent, and starts a conversation without reading documentation or filing a ticket. The onboarding wizard steps through environment setup, agent configuration, and first run in a single guided flow.

**Vaults for credential swapping.** A Vault is a scoped set of encrypted env-var overrides applied per conversation. Teams use Vaults to run the same agent under different GitHub identities or API keys without redefining the underlying Environment. Vault values win over Environment secrets on collision — making it easy to hand a contractor a scoped credential set while keeping baseline configuration shared.

**In-browser log viewer.** Every conversation's stdout, stderr, and lifecycle events stream in real time directly in the dashboard. No `curl -N` to a raw SSE endpoint, no log aggregation setup, no waiting for a turn to finish before seeing what happened. Debugging a stuck sandbox takes seconds.

**Three surfaces, one data model.** Fountain exposes a REST API for automation, a Phoenix LiveView dashboard for interactive use, and an `aod` CLI preconfigured to point at the hosted service. All three surfaces operate on the same Environments, Agents, and Conversations. Developers script against the API; less technical teammates use the dashboard; CI pipelines call the CLI. The choice of interface doesn't fragment the configuration.

**Per-tenant secret encryption.** Every Environment's secrets are encrypted with a per-tenant data key. Fountain never stores plaintext credentials. Sandbox quotas are enforced per user — one tenant cannot exhaust capacity for others. An admin debugging a stuck conversation sees status and log output, not the underlying key material.

---

## In Their Own Words

> "We were maintaining three separate `.env` files and a shared Notion doc to keep our agent configs in sync. Every time someone's API key rotated, we'd spend an hour tracking down which conversation had stale credentials. Fountain replaced all of it. We define the environment once, swap credentials with a Vault when we need to, and every team member starts from the same baseline. Onboarding the last two engineers took ten minutes each."
>
> — Engineering lead, early access customer

---

## Get Started

Fountain is available today. Sign up at [fountain.dev](https://fountain.dev) and start your first sandboxed conversation in under ten minutes.

Teams migrating from a self-hosted `aod-ex` instance can import existing Environments and Agents via the REST API. Primitives are backwards-compatible — if you already understand Environments, Vaults, and Agents, you already understand Fountain.

---

*Fountain — managed agent infrastructure for teams who'd rather build than configure.*
