# Fountain

Fountain is a **multi-tenant API** for managing agents, repos, secrets and
conversations, with an operator console over it and standalone apps for
watching an agent work. It is for people who want sandboxed coding agent
instances with preconfigured sets of env vars, MCP servers, skills, repos and
packages.

!!! tip "In a hurry?"
    Install the CLI and point it at a Fountain instance:
    ```sh
    brew install BinaryBourbon/tap/fountain
    fountain auth login
    fountain apply -f agent-specs
    ```

## The problem

Running coding agents on your own machine works until there is more than one of
you.

Setup does not travel. A new engineer spends an afternoon reverse-engineering
which MCP servers, skills and env vars the last person had, because the
configuration lives in a laptop rather than anywhere shared.

Credentials drift. There is no single source of truth for a key, so the wrong
`.env` silently breaks an agent and nobody finds out until a run fails
strangely.

Parallel work forces duplication. Two tasks needing different credentials means
two checkouts, two configurations, and two things to keep in sync.

Sandboxing is nobody's afternoon project. Giving an agent a machine that is
isolated, disposable and cheap when idle is real infrastructure work, and it is
not the work you were trying to do.

Fountain makes the configuration an API object, the credentials a layered
merge, and the machine something that is provisioned per run and reclaimed when
it goes quiet.

## Start here

- **[The guided tour](tour.md)** builds an agent that clones a repo, makes a
  change and opens a pull request, then takes a revision that lands on the same
  PR. About forty lines. Start here if you have not used Fountain.
- **[The four primitives](primitives.md)** explains the data model and why it
  is split four ways.

## Understand it

- [The four primitives](primitives.md), and one page each for
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md) and
  [Conversation](concepts/conversation.md)
- [Agents as teammates](concepts/teammates.md), why a teammate is not a fifth
  primitive
- [Where a secret comes from](concepts/secrets.md), the chain from the master
  key to the agent's process
- [About sandboxes](concepts/sandboxes.md), the machine a conversation runs on
- [The console, the apps, and the API](concepts/surfaces.md), why watching an
  agent work happens somewhere else
- [Architecture](architecture.md), what runs, what it talks to, and what breaks
  when a dependency is down
- [Why a bot needs more than a chat UI](build/index.md), the case for the API
  underneath

## Build with it

- [The guided tour](tour.md), an agent that opens a pull request
- [Build a chat app](build/team-chat.md), a roster-and-threads app end to end
- [Plugging into Fountain](integrations/clients.md), editors, chat surfaces,
  plugins and SDKs
- [LLM integration](llm-integration.md), connect any agentic IDE through
  `/skill`

## Run it

- [Local setup](setup.md), bootstrap a workstation in about ten minutes
- [Self-hosting](self-hosting.md), what you need and which guide to read
- [Deploy an instance](guides/operate/deploy.md), the first one to read
- [Troubleshooting](troubleshooting/index.md), start from the symptom
- [Operations](operations.md), running one day to day
- [Services Fountain uses](integrations/index.md), sandboxes, mail, OAuth,
  billing and errors

## Look it up

- [Catalog](catalog/index.md), runtimes and skills
- [CLI reference](cli.md), the `fountain` command surface
- [API reference](api.md), REST endpoints and auth
- [TypeScript SDK](sdk.md)
- [Configuration reference](configuration.md), every environment variable
- [Conversation states](reference/conversation-states.md)
- [Glossary](reference/glossary.md), including the five overloaded words
