# Bitwarden Secrets Manager (`bws://`)

Use the Bitwarden Secrets Manager CLI to resolve `bws://<uuid>` references at `aod apply` time. AoD calls `bws secret get` on your machine — it never sees your Bitwarden master password.

> **Note:** This is the **Secrets Manager** CLI (`bws`), not the personal vault CLI (`bw`). Secrets Manager is designed for IaC / CI flows and uses access tokens + UUID addressing.

## Prerequisites

- A Bitwarden Secrets Manager account: https://bitwarden.com/products/secrets-manager/
  (Separate from the personal vault; free tier available for small teams.)
- The `bws` CLI installed: https://bitwarden.com/help/secrets-manager-cli/

```bash
# macOS
brew install bitwarden/brew/bws

# Linux / Windows — download from the releases page:
# https://github.com/bitwarden/sdk-sm/releases
```

## Auth

`bws` authenticates with a machine access token. AoD reads `BWS_ACCESS_TOKEN` from your environment and passes it to `bws` — it's never written to the database.

**Generate a token in the Bitwarden dashboard:**

1. Open your Bitwarden Secrets Manager project.
2. Go to **Machine Accounts** → **New machine account**.
3. Grant it read access to the secrets you need.
4. Copy the access token — it's only shown once.

**Set it before running `aod apply`:**

```bash
export BWS_ACCESS_TOKEN=0.your-token-here...
./aod apply -f aod.yml
```

Or inline:

```bash
BWS_ACCESS_TOKEN=0.your-token-here... ./aod apply -f aod.yml
```

## URI format

```
bws://<secret-uuid>
```

The UUID uniquely identifies a secret within your Bitwarden Secrets Manager organization. There is no vault/item hierarchy — just a flat UUID.

**Find the UUID** in the dashboard (hover a secret → copy ID) or with the CLI:

```bash
BWS_ACCESS_TOKEN=... bws secret list
```

Output:

```json
[
  {
    "id": "11111111-1111-1111-1111-111111111111",
    "key": "GITHUB_TOKEN",
    "value": "ghp_...",
    ...
  }
]
```

Use the `id` field as the UUID in your manifest.

## Example manifest

```yaml
---
apiVersion: aod/v1
kind: Environment
metadata:
  name: ravi-hq
spec:
  packages:
    apt: [jq, ripgrep]
  secrets:
    GITHUB_TOKEN: bws://11111111-1111-1111-1111-111111111111
    ANTHROPIC_API_KEY: bws://22222222-2222-2222-2222-222222222222
    NPM_TOKEN: bws://33333333-3333-3333-3333-333333333333

---
apiVersion: aod/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's credentials
  secrets:
    GITHUB_TOKEN: bws://c0ffee00-dead-beef-cafe-123456789abc
```

Apply:

```bash
BWS_ACCESS_TOKEN=0.your-token... ./aod apply -f aod.yml
```

Output:

```
env    +  ravi-hq
  secret  +  ravi-hq/GITHUB_TOKEN
  secret  +  ravi-hq/ANTHROPIC_API_KEY
  secret  +  ravi-hq/NPM_TOKEN
vault  +  alice
  secret  +  alice/GITHUB_TOKEN
```

## Troubleshooting

**`bws` not on PATH**

```
GITHUB_TOKEN (bws://be8e0ad8-...): Bitwarden Secrets Manager CLI (`bws`) not on PATH — install from https://bitwarden.com/help/secrets-manager-cli/
```

Install `bws` and make sure it's in your `PATH`.

**Invalid or missing access token**

```
GITHUB_TOKEN (bws://be8e0ad8-...): Error: invalid access token
```

Check that `BWS_ACCESS_TOKEN` is set and not expired. Rotate the token in the Bitwarden dashboard if needed.

**UUID not found**

```
GITHUB_TOKEN (bws://be8e0ad8-...): Error: resource not found
```

Verify the UUID with `bws secret list` and confirm the machine account has read access to that secret.

**Missing UUID**

```
GITHUB_TOKEN (bws://): bws://<uuid> reference is missing the UUID
```

The URI must include the full UUID after `bws://`.
