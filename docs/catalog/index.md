# Catalog

Here are the things you can plug into an agent, and the things Fountain plugs
into.

Each entry has the same shape. Read one and you can skim the rest.

## Choose an agent's parts

| Catalog | An entry is | Count |
|---|---|---|
| [Runtimes](runtimes/index.md) | One coding-agent CLI that a sandbox can run. | 4 |
| [Skills](skills/index.md) | One `SKILL.md` that Fountain writes into the sandbox. | 2 bundled, and any repo on GitHub. |
| [MCP servers](mcp-servers/index.md) | One server that gives the runtime tools. | 3 hosted, and any server you declare. |

## Start from a whole agent

[Agents](agents/index.md) is the catalog of ready-to-apply manifests. One
file holds an Environment, a Vault and an Agent, and one `fountain apply -f`
reconciles all three. There is 1 entry, a
[Fountain contributor](agents/fountain-contributor.md).

## Elsewhere in these docs

Two catalogs are older than this section, and they keep their own pages for
now.

**[Sandbox providers](../integrations/sandbox-contract.md).** Where a
conversation's machine comes from. Sprites, E2B, Daytona, or a machine you own
through `fountain runner`.

**[Services Fountain uses](../integrations/index.md).** What an operator
configures. Mail, GitHub OAuth, Stripe, Sentry.

**[Plug into Fountain](../integrations/clients.md).** What drives Fountain
from outside. Editors, chat surfaces, plugin hosts, relays, and your own code.

## What is not here yet

**A list of third-party MCP servers.** Fountain hosts three of its own and
documents those. No curated list says which external servers work.
[#908](https://github.com/BinaryBourbon/fountain/issues/908) tracks it. Before
such a list could be honest, somebody must decide what "supported" would mean.

If you want an entry that does not exist, open an issue. The entry template is
`docs-redesign/05-catalog-template.md` in the repository.
