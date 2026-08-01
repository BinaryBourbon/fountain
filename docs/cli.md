# CLI reference

The `fountain` binary manages Fountain resources from the terminal or CI scripts.
It is a convenience wrapper over the REST API — everything here can be done with
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
```

`run` creates a conversation and streams until the turn reaches a terminal state.

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

Disconnecting loses nothing — reattach at any time:

```bash
fountain conv stream <conversation-id>
```

## Apply manifests

```bash
fountain apply -f path/to/manifest.yml
fountain apply -f path/to/directory/          # walks all *.yml / *.yaml files
fountain apply -f dir/ --var REGION=eu-west-1 # ${VAR} substitution, repeatable
```

Apply is idempotent — create if new, update if changed. Supported kinds:
`Environment`, `Vault`, `Agent`.

The CLI compiles every document into a single manifest and sends it to
`POST /api/apply` in one request; the server reconciles environments, then
vaults, then agents, and resolves agent `environment:` name references —
including environments that already exist on the server. Against older servers
without `/api/apply`, the CLI falls back to per-resource calls.

## API keys

```bash
fountain keys list
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
with one section per profile:

```ini
[default]
api_key = ftn_...
base_url = https://fountain.inevitable.fyi
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
active profile in the credentials file, then — for the URL only — the built-in
default `https://fountain.inevitable.fyi`.
