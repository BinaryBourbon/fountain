# CLI reference

The `fountain` binary manages Fountain resources from the terminal or CI scripts.

## Install

```bash
brew install BinaryBourbon/tap/fountain
```

Or grab a release binary from the [GitHub Releases](https://github.com/BinaryBourbon/fountain/releases) page.

## Authentication

```bash
fountain auth login        # prompts for email + password
fountain auth logout
fountain auth status
```

Target a non-default instance:

```bash
fountain auth login --endpoint https://your-fountain.example.com
```

## Apply manifests

```bash
fountain apply -f path/to/manifest.yml
fountain apply -f path/to/directory/    # walks all *.yml / *.yaml files
```

Apply is idempotent - create if new, update if changed. Supported kinds: `Environment`, `Vault`, `Agent`.

## Read resources

```bash
fountain get agents
fountain get environments
fountain get vaults
fountain get conversations

fountain get agent my-agent-name
```

## Inspect a resource

```bash
fountain describe agent my-agent-name
fountain describe conversation <id>
```

## Delete

```bash
fountain delete agent my-agent-name
fountain delete environment python-data-env
```

## Start a conversation

```bash
fountain run agent my-agent-name --prompt "Audit the auth module"
fountain run agent my-agent-name --vault staging-creds --prompt "Run the test suite"
```

`run` streams log output until the conversation completes, then prints the final result.

## Output formats

```bash
fountain get agents -o json
fountain get agents -o yaml
fountain get agents -o table   # default
```

## Configuration file

`~/.fountain/credentials` is written by `fountain auth login`:

```yaml
endpoint: https://founta.inevitable.fyi
token: ft_...
```

Per-invocation overrides:

```bash
FOUNTAIN_TOKEN=ft_... fountain get agents
FOUNTAIN_ENDPOINT=https://other.example.com fountain get agents
```
