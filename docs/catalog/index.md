# Catalog

The things you can plug into an agent, and the things Fountain plugs into.

Each entry follows the same shape, so once you have read one you can skim the
rest.

## Pick an agent's parts

| Catalog | An entry is | Count |
|---|---|---|
| [Runtimes](runtimes/index.md) | one coding-agent CLI a sandbox can run | 4 |
| [Skills](skills/index.md) | one `SKILL.md` written into the sandbox | 2 bundled, plus anything on GitHub |

## Elsewhere in these docs

Two catalogs predate this section and keep their own pages for now.

**[Sandbox providers](../integrations/sandbox-contract.md).** Where a
conversation's machine comes from. Sprites, E2B, Daytona, or a machine you own
through `fountain runner`.

**[Services Fountain uses](../integrations/index.md).** What an operator
configures. Mail, GitHub OAuth, Stripe, Sentry.

**[Plugging into Fountain](../integrations/clients.md).** What drives Fountain
from outside. Editors, chat surfaces, plugin hosts, relays, your own code.

## What is not here yet

**MCP servers.** `mcp_servers` is a first-class Agent field and there is no
list of what works. Tracked in
[#908](https://github.com/BinaryBourbon/fountain/issues/908), and it needs a
decision about what "supported" means before it can be written honestly.

If you want an entry that does not exist, open an issue. The entry template is
in `docs-redesign/05-catalog-template.md` in the repository.
