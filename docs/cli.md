# CLI reference

The `fountain` binary manages Fountain resources from the terminal or CI scripts.
It is a convenience wrapper over the REST API. Everything here can be done with
`curl`.

This page tracks the real command tree. If a command is not listed here it does
not exist; `fountain <command> --help` is authoritative.

## Install

```bash
brew install BinaryBourbon/tap/fountain
```

Or grab a release binary from the [GitHub Releases](https://github.com/BinaryBourbon/fountain/releases) page.

## Authentication

```bash
fountain auth login     # prompts for email + password, saves an API key
fountain auth whoami    # print the current user
fountain auth logout    # remove saved credentials
```

`auth login` has no `--endpoint` flag. Point the CLI at a different instance with
`FOUNTAIN_BASE_URL`, which `auth login` then records in the saved profile:

```bash
FOUNTAIN_BASE_URL=https://your-fountain.example.com fountain auth login
```

### Profiles

Use `--profile` (or `FOUNTAIN_PROFILE`) to keep several instances side by side:

```bash
FOUNTAIN_BASE_URL=https://staging.example.com fountain auth login --profile staging
fountain conv list --profile staging
```

## Agents

```bash
fountain agent list [--json]
fountain agent show <id>
```

Agents are **read-only** from the CLI. Create and update them with
[`fountain apply`](#apply-manifests) or the REST API.

## Environments

```bash
fountain env list [--json]
fountain env show <id>
```

Also read-only. Environment secrets are set through `apply` or the API.

## Vaults

Vaults are the one resource with a full CLI surface, because they hold the
per-conversation credentials you most often want to change without editing a
manifest.

```bash
fountain vault list [--json]
fountain vault show <id-or-name>
fountain vault create <name> [--description "..."]
fountain vault delete <id-or-name>

fountain vault set-secret <id-or-name> <key> <value>
fountain vault delete-secret <id-or-name> <key>
```

## Hosted Buzz agents

The one knob a hosted [Buzz](integrations/buzz.md) agent needs after it is
deployed: who may `@`-mention it. The Buzz desktop refuses to change access on
a provider agent it has already deployed, so this is where the policy changes.
Setting it restarts the agent's harness so the new gate is live.

```bash
fountain buzz agents list [--json]
fountain buzz agents set-access <name-or-id> --respond-to anyone
fountain buzz agents set-access <name-or-id> --respond-to allowlist --allowlist <hex>,<hex>
fountain buzz agents set-access <name-or-id> --respond-to owner-only
```

`--respond-to` is one of `owner-only`, `allowlist`, `anyone`, `nobody`
(`buzz-acp`'s own modes). Only the flags you pass change; `--respond-to` alone
keeps the stored allowlist. Note that a later provider deploy from the desktop
resends the desktop's own record and overwrites what is set here.

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

`-i/--image` is repeatable and takes local file paths.

## Run an agent

```bash
fountain run <agent-name-or-id> -p "Audit the auth module"
fountain run <agent-name-or-id> -p "Run the test suite" --vault staging-creds
fountain run <agent-name-or-id> -p "Run the test suite" --environment staging
```

`run` creates a conversation and streams until the turn reaches a terminal state.
`--vault` layers a vault's secrets over the agent's environment (vault wins on
collision); `--environment` provisions from that environment instead of the
agent's own.

### Long-running turns

The server closes an idle SSE connection after 60 seconds, so a turn that thinks
for a while without printing will see the connection drop. The CLI reconnects
using `Last-Event-ID`, so output produced while disconnected is replayed and a
dropped connection is never mistaken for a finished turn.

If nothing arrives at all for 30 minutes the CLI exits with an error naming the
conversation, rather than reporting success. Widen the wait with
`FOUNTAIN_STREAM_IDLE_TIMEOUT` (seconds):

```bash
FOUNTAIN_STREAM_IDLE_TIMEOUT=7200 fountain run researcher -p "large refactor"
```

Disconnecting loses nothing. Reattach at any time:

```bash
fountain conv stream <conversation-id>
```

## Editor integration (ACP)

```bash
fountain acp --agent <name-or-id> [--vault <name-or-id>] [--environment <name-or-id>] [--log-level debug]
```

Speaks the [Agent Client Protocol](https://agentclientprotocol.com) on stdio, so
an ACP-capable editor can drive a Fountain conversation. You do not run this
yourself. The editor spawns it and talks JSON-RPC over the pipe. stdout carries
the protocol and nothing else; diagnostics go to stderr, which is where to look
first when an editor reports a problem.

`--agent` names the Fountain agent that sessions run: the protocol has no field
for it, so it is configured on the command line, one editor entry per agent.
Credentials are the ones `fountain auth login` already saved, and `--profile`
selects the instance.

**[`fountain acp` (reference)](integrations/acp.md)** documents the protocol
surface and flags in full; **[Editors (ACP)](integrations/editors.md)** has the setup, the editor config
snippets, and the limits worth knowing before you start. Chief among them is
that the agent works on a sandbox's files, not the ones open in your editor.

## Self-hosted runner

```bash
fountain runner                          # this machine becomes a sandbox provider
fountain runner --name mini --root ~/fountain-sandboxes --log-level debug
```

Dials out to Fountain, holds the connection, and serves sandboxes for agents
whose `sandbox_provider` is `runner`: each sandbox is a directory under
`--root` (default `~/.fountain/runners/<name>/sandboxes`), the agent's
processes run on this machine as you with `HOME` pointed at that directory,
and idle sandboxes park by stopping their processes with the directory left
in place. Trusted mode, with no VM and no egress policy, so run it on a machine
you would hand a capable colleague a shell on. Needs a full-scope key. Names are
unique per account (default: the hostname); reconnects with backoff. See the
[runners guide](integrations/runners.md).

## Apply manifests

```bash
fountain apply -f path/to/manifest.yml
fountain apply -f path/to/directory/          # walks all *.yml / *.yaml files
fountain apply -f dir/ --var REGION=eu-west-1 # ${VAR} substitution, repeatable
```

Apply is idempotent, creating if new and updating if changed. The supported
kinds are `Environment`, `Vault` and `Agent`.

`--var`/`${VAR}` substitution applies to `spec.secrets` values only. A
`${VAR}` anywhere else in the document (a `setup_script`, a name) is
transmitted literally.

The CLI compiles every document into a single manifest and sends it to
`POST /api/apply` in one request; the server reconciles environments, then
vaults, then agents, and resolves agent `environment:` name references,
including environments that already exist on the server. Against older servers
without `/api/apply`, the CLI falls back to per-resource calls.

### Secret references

`spec.secrets` values can reference a secret manager instead of holding
plaintext. That is what makes manifests committable to git. A value starting
with one of these schemes is resolved client-side at apply time by shelling
out to the manager's own CLI (which must be installed and authenticated):

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

Resolution failures (and empty values, which nearly always mean "secret not
found") fail the apply for that document rather than writing an empty secret.
Only `spec.secrets` values are resolved; the schemes are inert anywhere else.

## API keys

```bash
fountain keys list [--json]
fountain keys create <name>     # prints the key once; it is not recoverable
fountain keys revoke <id>
```

## Output

List commands accept `--json`. There is no `-o` flag and no YAML output:

```bash
fountain agent list --json | jq '.[].name'
```

## Configuration

`~/.fountain/credentials` is an INI-style file written by `fountain auth login`,
with one section per profile (values are written double-quoted):

```ini
[default]
api_key = "ftn_..."
base_url = "https://fountain.inevitable.fyi"
```

The file is written `0600` and the directory `0700`.

### Environment variables

| Variable | Effect |
|---|---|
| `FOUNTAIN_API_KEY` | API key; takes precedence over the credentials file |
| `FOUNTAIN_BASE_URL` | Instance URL; takes precedence over the credentials file |
| `FOUNTAIN_PROFILE` | Profile to use, equivalent to `--profile` |
| `FOUNTAIN_STREAM_IDLE_TIMEOUT` | Seconds of silence before a stream gives up (default 1800) |

```bash
FOUNTAIN_API_KEY=ftn_... FOUNTAIN_BASE_URL=https://other.example.com fountain agent list
```

Resolution order for both the key and the URL is: environment variable, then the
active profile in the credentials file, then (for the URL only) the built-in
default `https://fountain.inevitable.fyi`.

**Self-hosting?** That built-in default is the hosted instance, not yours. Run
`fountain auth login` with `FOUNTAIN_BASE_URL` pointed at your instance before
anything else: an unconfigured CLI with `FOUNTAIN_API_KEY` exported sends that
key to `fountain.inevitable.fyi`. Configure the URL before the key.
