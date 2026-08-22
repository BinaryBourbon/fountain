# CLI reference

The `fountain` binary manages Fountain resources from a terminal, or from a CI
script. It is a convenience wrapper over the REST API. You can do everything
here with `curl`.

This page follows what you want to do. It shows the useful invocations, and
not each flag. For the complete list of flags, which comes
from the binary itself, read [All commands](cli/commands.md).

A command that is on neither of these two pages does not exist. A test walks
the real command tree, and it fails either way round.

## Install

```bash
brew install BinaryBourbon/tap/fountain
```

Or take a release binary from the
[GitHub Releases](https://github.com/BinaryBourbon/fountain/releases) page.

## Authentication

```bash
fountain auth login     # prompts for email + password, saves an API key
fountain auth whoami    # print the current user
fountain auth logout    # remove saved credentials
```

`auth login` has no `--endpoint` flag. Point the CLI at a different instance
with `FOUNTAIN_BASE_URL`. `auth login` then records that URL in the saved
profile.

```bash
FOUNTAIN_BASE_URL=https://your-fountain.example.com fountain auth login
```

### Profiles

Use `--profile`, or `FOUNTAIN_PROFILE`, to keep several instances side by
side.

```bash
FOUNTAIN_BASE_URL=https://staging.example.com fountain auth login --profile staging
fountain conv list --profile staging
```

## Agents

```bash
fountain agent list [--json]
fountain agent show <id>
```

An agent is **read-only** from the CLI. Create one and update one with
[`fountain apply`](#apply-manifests), or with the REST API.

## Environments

```bash
fountain env list [--json]
fountain env show <id>
```

These are read-only too. Set an environment secret through `apply`, or through
the API.

## Vaults

A vault is the one resource with a full CLI surface. A vault holds the
credentials for one conversation, and those are the ones you most often want
to change with no edit to a manifest.

```bash
fountain vault list [--json]
fountain vault show <id-or-name>
fountain vault create <name> [--description "..."]
fountain vault delete <id-or-name>

fountain vault set-secret <id-or-name> <key> <value>
fountain vault delete-secret <id-or-name> <key>
```

## Hosted Buzz agents

These commands change the inbound gate on a hosted
[Buzz](integrations/buzz.md) agent. The gate decides whose `@`-mention the
harness answers.

The Buzz desktop refuses to change access on a provider agent it already
deployed. So this is where that gate changes. To set it restarts the harness,
and the new gate is then live.

**This does not make the agent mentionable.** Buzz Desktop 0.5.17 and newer
builds its agent directory from the owner-signed kind-30177 policy that the
desktop published at deploy. It does not build it from what the harness
advertises.

So open the gate here, publish that policy again, and other users can send the
mention. Open the gate alone, and they cannot send it at all. Read
[Who may talk to it](integrations/buzz.md#who-may-talk-to-it).

```bash
fountain buzz agents list [--json]
fountain buzz agents set-access <name-or-id> --respond-to anyone
fountain buzz agents set-access <name-or-id> --respond-to allowlist --allowlist <hex>,<hex>
fountain buzz agents set-access <name-or-id> --respond-to owner-only
```

`--respond-to` is one of `owner-only`, `allowlist`, `anyone` and `nobody`.
Those are `buzz-acp`'s own modes. Only the flags you pass change, so
`--respond-to` on its own keeps the stored allowlist.

A later provider deploy from the desktop sends the desktop's own record again,
and overwrites what you set here.

## Conversations

```bash
fountain conv list [--json]
fountain conv show <id>
fountain conv stream <id>
fountain conv prompt <id> -p "next instruction" [-i screenshot.png]
fountain conv interrupt <id>
fountain conv terminate <id>
fountain conv delete <id>
```

You can repeat `-i` and `--image`. Each one takes a local file path.

## Run an agent

```bash
fountain run <agent-name-or-id> -p "Audit the auth module"
fountain run <agent-name-or-id> -p "Run the test suite" --vault staging-creds
fountain run <agent-name-or-id> -p "Run the test suite" --environment staging
```

`run` creates a conversation, then streams until the turn reaches a terminal
state.

`--vault` layers a vault's secrets over the agent's environment, and the vault
wins on a collision. `--environment` provisions from that environment, and not
from the agent's own.

### Long-running turns

The server closes an idle SSE connection after 60 seconds. So a turn that
thinks for a while and prints nothing loses its connection.

The CLI reconnects with `Last-Event-ID`. It replays the output that arrived
while it had no connection, and it never mistakes a dropped connection for a
finished turn.

If nothing at all arrives for 30 minutes, the CLI exits with an error that
names the conversation. It does not report success. Widen the wait with
`FOUNTAIN_STREAM_IDLE_TIMEOUT`, in seconds.

```bash
FOUNTAIN_STREAM_IDLE_TIMEOUT=7200 fountain run researcher -p "large refactor"
```

A disconnect loses nothing. Reattach at any time.

```bash
fountain conv stream <conversation-id>
```

## Editor integration (ACP)

```bash
fountain acp --agent <name-or-id> [--vault <name-or-id>] [--environment <name-or-id>] [--log-level debug]
```

This speaks the [Agent Client Protocol](https://agentclientprotocol.com) on
stdio, so an ACP-capable editor can drive a Fountain conversation.

You do not run it yourself. The editor spawns it, and talks JSON-RPC over the
pipe. stdout carries the protocol and nothing else. Diagnostics go to stderr,
and that is where to look first when an editor reports a problem.

`--agent` names the Fountain agent that a session runs. The protocol has no
field for it, so you configure it on the command line, with one editor entry
for each agent.

The credentials are the ones that `fountain auth login` already saved.
`--profile` chooses the instance.

**[`fountain acp` (reference)](integrations/acp.md)** documents the protocol
surface and the flags in full. **[Editors (ACP)](integrations/editors.md)**
has the setup, the editor config snippets, and the limits that matter before
you start.

The first of those limits is that the agent works on a sandbox's files. It
does not work on the files open in your editor.

## Self-hosted runner

```bash
fountain runner                          # this machine becomes a sandbox provider
fountain runner --name mini --root ~/fountain-sandboxes --log-level debug
```

This dials out to Fountain, holds the connection, and serves sandboxes for an
agent whose `sandbox_provider` is `runner`.

Each sandbox is a directory under `--root`, which defaults to
`~/.fountain/runners/<name>/sandboxes`. The agent's processes run on this
machine as you, with `HOME` pointed at that directory. An idle sandbox parks:
it stops its processes, and the directory stays.

Fountain trusts this machine, and gives it no VM and no egress policy. Run it
where you would hand a capable colleague a shell. It needs a full-scope key.
A name is unique for each account, and it defaults to the hostname. It
reconnects with backoff. Read the
[runners guide](integrations/runners.md).

## Apply manifests

```bash
fountain apply -f path/to/manifest.yml
fountain apply -f path/to/directory/          # walks all *.yml / *.yaml files
fountain apply -f dir/ --var REGION=eu-west-1 # ${VAR} substitution, repeatable
```

Apply is idempotent. It creates what is new, and updates what changed. It
supports three kinds, which are `Environment`, `Vault` and `Agent`.

`--var` and `${VAR}` substitution apply to a `spec.secrets` value alone. A
`${VAR}` anywhere else in the document goes across as it stands. A
`setup_script` and a name are two such places.

The CLI compiles each document into one manifest, and sends that to
`POST /api/apply` in one request.

The server reconciles the environments, then the vaults, then the agents. It
resolves an agent's `environment:` name reference, and that includes an
environment that already exists on the server.

Against an older server with no `/api/apply`, the CLI falls back to one call
for each resource.

### Secret references

A `spec.secrets` value can point at a secret manager, and hold no plaintext.
That is what lets you commit a manifest to git.

The CLI resolves a value that starts with one of these schemes, on the client,
at apply time. It runs the manager's own CLI, which you must install and
authenticate first.

| Scheme | Manager | Resolved with |
|---|---|---|
| `op://vault/item/field` | 1Password | `op read` |
| `bws://<secret-uuid>` | Bitwarden Secrets Manager | the `bws` CLI |
| `infisical://<project?>/<env>/<path?>/<name>` | Infisical | the `infisical` CLI |

```yaml
kind: Vault
metadata: { name: prod-tokens }
spec:
  secrets:
    GITHUB_TOKEN: op://Private/github/token
    STRIPE_KEY: bws://8f0a3c1e-...
```

A failure to resolve fails the apply for that document. So does an empty
value, which nearly always means the manager found no secret. The CLI writes
no empty secret.

The CLI resolves a `spec.secrets` value alone. The schemes are inert anywhere
else.

## API keys

```bash
fountain keys list [--json]
fountain keys create <name>     # prints the key once; it is not recoverable
fountain keys revoke <id>
```

## Output

A list command accepts `--json`. There is no `-o` flag, and there is no YAML
output.

```bash
fountain agent list --json | jq '.[].name'
```

## Configuration

`fountain auth login` writes `~/.fountain/credentials`, an INI-style file with
one section for each profile. It writes each value in double quotes.

```ini
[default]
api_key = "ftn_..."
base_url = "https://fountain.inevitable.fyi"
```

The CLI writes the file `0600`, and the directory `0700`.

### Environment variables

| Variable | Effect |
|---|---|
| `FOUNTAIN_API_KEY` | The API key. It wins over the credentials file. |
| `FOUNTAIN_BASE_URL` | The instance URL. It wins over the credentials file. |
| `FOUNTAIN_PROFILE` | The profile to use. It is the same as `--profile`. |
| `FOUNTAIN_STREAM_IDLE_TIMEOUT` | The seconds of silence before a stream gives up. The default is 1800. |

```bash
FOUNTAIN_API_KEY=ftn_... FOUNTAIN_BASE_URL=https://other.example.com fountain agent list
```

The CLI resolves both the key and the URL in the same order. It reads the
environment variable, then the active profile in the credentials file. For the
URL alone it then falls back to the built-in default,
`https://fountain.inevitable.fyi`.

**Do you self-host?** That built-in default is the hosted instance, and not
yours.

Run `fountain auth login` with `FOUNTAIN_BASE_URL` pointed at your instance.
Do that first, before each other command. A CLI with no config, and `FOUNTAIN_API_KEY`
exported, sends that key to `fountain.inevitable.fyi`. Configure the URL
before the key.
