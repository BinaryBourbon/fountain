# Glossary

Terms Fountain uses, and the five that are overloaded. Where a word has more
than one sense, the senses are listed and the docs pick one.

## The overloaded words

### Agent

Three senses. The docs mean the first.

1. **The primitive.** A named, re-runnable configuration. See
   [About agents](../concepts/agent.md).
2. **The coding agent.** The process running inside the sandbox, which is
   Claude Code, Codex, Gemini CLI or opencode. The docs call this the
   **runtime**.
3. **The ACP role.** In the Agent Client Protocol, the process an editor
   spawns. The docs call this `fountain acp`. See
   [`fountain acp`](../integrations/acp.md).

### Environment

Three senses. The docs mean the first.

1. **The primitive.** See [About environments](../concepts/environment.md).
2. **Environment variables.** The values in a process. The docs always say
   "environment variables" in full.
3. **A deployment tier.** Dev, staging, production. The docs say
   **deployment** for this and never "environment".

### Fountain

Three senses, distinguished by formatting.

1. **Fountain**, unstyled, is the product.
2. **`fountain`**, in code font, is the CLI binary.
3. **the `fountain` skill** is the skill injected into every sandbox, which
   gives an agent Fountain's own API. Always written with the word "skill".

### Vault

Two senses, and they are close to opposite. The docs mean the first.

1. **The primitive.** A small, static, per-run override layer that wins on key
   collision. See [About vaults](../concepts/vault.md).
2. **HashiCorp Vault.** A central server issuing dynamic leased credentials.
   Unrelated to Fountain's Vault beyond the shape of the encryption. The
   collision is set out on the Vault page.

### Computer

Used in the team and conversations apps for the machine a teammate works on.
The docs say **sandbox**.

## The rest

| Term | Means |
|---|---|
| **ACP** | Agent Client Protocol. How editors and chat surfaces drive Fountain. See [`fountain acp`](../integrations/acp.md) |
| **AG-UI** | The protocol OpenBot and other coworker hosts speak. See [OpenBot](../integrations/openbot.md) |
| **Conversation** | One run of an Agent in a sandbox. See [About conversations](../concepts/conversation.md) |
| **DEK** | Data encryption key. Derived per tenant from `MASTER_SECRETS_KEY` and used to encrypt that tenant's secrets |
| **Inference credentials** | A user's own model provider keys, entered in the running app. Never set by an operator. See [Services Fountain uses](../integrations/index.md) |
| **Log event** | One entry in a conversation's stream. Delivered over SSE, optionally pre-parsed with `?blocks=true` |
| **MCP server** | A Model Context Protocol server an Agent gives its runtime. Declared in `mcp_servers` |
| **Reaper** | The background sweep that suspends idle sandboxes and destroys ones past the ceiling |
| **Runner** | A machine you own, running `fountain runner`, acting as a sandbox provider. See [Self-hosted runners](../integrations/runners.md) |
| **Runtime** | The coding-agent CLI a sandbox runs. One of `claude`, `codex`, `gemini`, `opencode` |
| **Sandbox** | The isolated machine one Conversation runs in. Provisioned at launch, reclaimed on the lifetime rules |
| **Sandbox provider** | A backend Fountain provisions sandboxes on. Sprites, E2B, Daytona, or a self-hosted runner. See [the sandbox contract](../integrations/sandbox-contract.md) |
| **Skill** | A `SKILL.md` written into the sandbox, inline or sourced from GitHub |
| **Sprite** | One sandbox on the Sprites provider. Not a Fountain concept. See [Sprites](../integrations/sprites.md) |
| **Substitution** | `${VAR}` interpolation in Agent config, resolved from the merged secrets at spawn |
| **Suspend** | Scaling a sandbox to zero while keeping its disk, so the agent's memory survives |
| **Teammate** | An Agent with one ongoing Conversation on the reserved channel `fountain:team`. Not a primitive. See [Agents as teammates](../concepts/teammates.md) |
| **Turn** | One prompt and the work that follows it, inside a Conversation |

## Two things that sound like primitives and are not

A **team** is not an object. See
[Agents as teammates](../concepts/teammates.md).

A **sandbox** is not an object you create. It is provisioned when a
Conversation starts and reclaimed when it ends. See
[About conversations](../concepts/conversation.md).
