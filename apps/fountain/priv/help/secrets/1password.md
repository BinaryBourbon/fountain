# 1Password (`op://`)

Use the 1Password CLI to resolve secret references at `fountain apply` time. Fountain calls `op read` on your machine — it never sees your 1Password credentials or master password.

## Prerequisites

- A 1Password account (individual, Teams, or Business).
- The `op` CLI installed: https://developer.1password.com/docs/cli/get-started

```bash
# macOS
brew install 1password-cli

# Linux (example — see install page for your distro)
curl -sSfLo op.zip https://cache.agilebits.com/dist/1P/op2/pkg/v2.x.x/op_linux_amd64_v2.x.x.zip
unzip -o op.zip && sudo mv op /usr/local/bin/
```

## Auth

`op` manages its own authentication. Fountain doesn't see your password, session token, or service account key.

**Interactive (local dev):** Sign in with biometric or password once before running `fountain apply`:

```bash
op signin
```

After signing in, `op` keeps a session alive for a configurable TTL (default 30 minutes). If the session expires mid-apply, you'll see:

```
POSTHOG_API_KEY (op://Work/PostHog/api_key): [ERROR] ... session expired
```

Run `op signin` again and re-apply.

**Service accounts (CI):** Create a service account token in 1Password and export it:

```bash
export OP_SERVICE_ACCOUNT_TOKEN=ops_...
fountain apply -f fountain.yml
```

## URI format

```
op://<vault>/<item>/<field>
```

| Segment | Description | Example |
|---------|-------------|---------|
| `vault` | Vault name (case-insensitive) or vault UUID | `Work`, `Personal` |
| `item` | Item name or item UUID | `PostHog`, `GitHub` |
| `field` | Field label (case-insensitive) or field ID | `api_key`, `token`, `password` |

Find the right path with:

```bash
op item list                          # list all items across vaults
op item list --vault Work             # list items in a specific vault
op item get PostHog --vault Work      # show item fields
```

## Example manifest

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: ravi-hq
spec:
  packages:
    apt: [jq, ripgrep]
  secrets:
    ANTHROPIC_API_KEY: op://Work/Anthropic/api_key
    POSTHOG_API_KEY: op://Work/PostHog/api_key
    GITHUB_TOKEN: op://Work/GitHub/token

---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's personal credentials
  secrets:
    GITHUB_TOKEN: op://Personal/GitHub/token
    NPM_TOKEN: op://Personal/npm/token
```

Apply:

```bash
op signin    # once per session
fountain apply -f fountain.yml
```

Output:

```
env    +  ravi-hq
  secret  +  ravi-hq/ANTHROPIC_API_KEY
  secret  +  ravi-hq/POSTHOG_API_KEY
  secret  +  ravi-hq/GITHUB_TOKEN
vault  +  alice
  secret  +  alice/GITHUB_TOKEN
  secret  +  alice/NPM_TOKEN
```

## Dynamic vault name

Combine `${VAR}` substitution with `op://` to keep the vault name configurable:

```yaml
secrets:
  ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/api_key
```

```bash
OP_VAULT=Work fountain apply -f fountain.yml
```

## Troubleshooting

**`op` not on PATH**

```
ANTHROPIC_API_KEY (op://Work/Anthropic/api_key): 1Password CLI (`op`) not on PATH — install from https://developer.1password.com/docs/cli/get-started
```

Install `op` and make sure it's in your `PATH`.

**Session expired**

```
ANTHROPIC_API_KEY (op://Work/Anthropic/api_key): [ERROR] ... session expired
```

Run `op signin` and re-apply.

**Item or field not found**

```
ANTHROPIC_API_KEY (op://Work/Anthropic/key): [ERROR] ... item "Anthropic" not found in vault "Work"
```

Double-check vault name, item name, and field label with `op item get <item> --vault <vault>`.
