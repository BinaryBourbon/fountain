# Fountain

Fountain is a **multi-tenant API**. It manages agents, repos, secrets and
conversations. An operator console sits on top of the API, and separate apps
let you watch an agent at work.

Fountain is for people who want sandboxed coding agents. Each agent starts
with the environment variables, MCP servers, skills, repos and packages that
you configured once.

!!! tip "In a hurry?"
    Install the CLI and log in. For your own instance, set `FOUNTAIN_BASE_URL`
    first, because the CLI defaults to the hosted one.
    ```sh
    brew install BinaryBourbon/tap/fountain
    fountain auth login
    fountain auth whoami
    ```
    The CLI now works, and you have no agent to run yet. The
    [guided tour](tour.md) builds the first one.

## The problem

A coding agent on your own machine works until there is more than one of you.

Your configuration does not move. A new engineer spends an afternoon to work
out which MCP servers, skills and environment variables the last person had.
The configuration lives on a laptop and not anywhere the team shares.

Credentials move apart. No one place holds the correct value of a key. The
incorrect `.env` breaks an agent without a sound, and nobody finds out until a
run fails in a strange way.

Parallel work makes you duplicate things. Two tasks that need different
credentials mean two checkouts and two configurations. You must then keep the
two in step.

Nobody builds a sandbox in an afternoon. An isolated machine that you can
discard, and that costs little when it is idle, is real infrastructure work. It
is also not the work you set out to do.

Fountain makes the configuration an API object. It makes the credentials a
layered merge. It makes the machine something Fountain gives you for one run,
then takes back when the run goes quiet.

## Start here

- **[The guided tour](tour.md)** builds an agent that clones a repo, changes it
  and opens a pull request. A second turn then lands a revision on the same PR.
  The tour is about forty lines. Start here if Fountain is new to you.
- **[The four primitives](primitives.md)** explains the data model, and why
  Fountain divides it four ways.

## Understand it

- [The four primitives](primitives.md), and one page each for
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md) and
  [Conversation](concepts/conversation.md)
- [Agents as teammates](concepts/teammates.md), and why a teammate is not a
  fifth primitive
- [Where a secret comes from](concepts/secrets.md), the chain from the master
  key to the agent's process
- [About sandboxes](concepts/sandboxes.md), the machine a conversation runs on
- [The console, the apps, and the API](concepts/surfaces.md), and why you watch
  an agent somewhere else
- [Architecture](architecture.md), what runs, what it talks to, and what breaks
  when a dependency is down
- [Why a bot needs more than a chat UI](build/index.md), the case for the API
  below it

## Build with it

- [The guided tour](tour.md), an agent that opens a pull request
- [Build a chat app](build/team-chat.md), a roster-and-threads app from start
  to finish
- [Plug into Fountain](integrations/clients.md), editors, chat surfaces,
  plugins and SDKs
- [LLM integration](llm-integration.md), how to connect an agentic IDE through
  `/skill`

## Run it

- [Local setup](setup.md), how to bootstrap a workstation in about ten minutes
- [Self-host Fountain](self-hosting.md), what you must have and which guide
  to read
- [Deploy an instance](guides/operate/deploy.md), the first one to read
- [Troubleshoot a problem](troubleshooting/index.md), which starts from the
  symptom
- [Operations](operations.md), how to run an instance day to day
- [Services Fountain uses](integrations/index.md), sandboxes, mail, OAuth,
  billing and errors <!-- vale disable-line STE.IngForms -->

## Look it up

- [Catalog](catalog/index.md), runtimes and skills
- [CLI reference](cli.md), the `fountain` command surface
- [API reference](api.md), REST endpoints and auth
- [TypeScript SDK](sdk.md)
- [Configuration reference](configuration.md), each environment variable
- [Conversation states](reference/conversation-states.md)
- [Glossary](reference/glossary.md), with the five overloaded words
