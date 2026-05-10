# Vaults

A **Vault** is a free-floating bag of encrypted env-var overrides that you pick when starting a conversation. Use them to switch the credentials a conversation runs under without redefining the environment.

The mental model:

- **Environment** — defines the sandbox shape and its baseline secrets (e.g. a default service-account `GITHUB_TOKEN`).
- **Vault** — defines _your_ credentials, a teammate's, or a virtual identity's (e.g. a personal `GITHUB_TOKEN`, an `OPENAI_API_KEY` for the role you're playing).
- **Conversation** — picks an agent (which references an environment) and optionally a vault. At sprite spawn, env secrets are merged with vault secrets; **vault wins on key collision**.

Vaults are not bound to a user, team, or environment — they're loose bags. v1 keeps it simple.

## Create one

```bash
curl -s -X POST "$AOD_BASE_URL/api/vaults" \
  -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"alice","description":"Alice'"'"'s GitHub + npm credentials"}'
```

Or via CLI:

```bash
aod vault create alice --description "Alice's GitHub + npm credentials"
```

## Add secrets

Vault secrets are AES-256-GCM encrypted at rest. Values are write-only — the API never returns them.

```bash
aod vault set-secret alice GITHUB_TOKEN ghp_alice_...
aod vault set-secret alice NPM_TOKEN    npm_alice_...
```

Equivalently:

```bash
curl -s -X POST "$AOD_BASE_URL/api/vaults/<vault_id>/secrets" \
  -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
  -d '{"key":"GITHUB_TOKEN","value":"ghp_alice_..."}'
```

## Use one when starting a conversation

```bash
aod run AODDocsWriter -p "Open a docs PR." --vault alice
```

Or via the API:

```bash
curl -s -X POST "$AOD_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" -H "Content-Type: application/json" \
  -d '{"agent_id":"<id>","vault_id":"<vault_id>","prompt":"..."}'
```

The vault binds at conversation creation. The conversation row records `vault_id`; mid-conversation prompt follow-ups don't change which vault is in effect — the sprite already has those env vars baked in.

## Override semantics

When the same key is set on both the environment and the vault, the vault wins:

```
env secrets:                 GITHUB_TOKEN=ghp_org_default
vault "alice" secrets:       GITHUB_TOKEN=ghp_alice_personal
                             NPM_TOKEN=npm_alice

→ sprite env: GITHUB_TOKEN=ghp_alice_personal
              NPM_TOKEN=npm_alice
```

Repository clones that reference `secret_key: GITHUB_TOKEN` see the vault's value too — same merged map.

## Manifest

Vaults are first-class in `aod apply`:

```yaml
---
apiVersion: aod/v1
kind: Vault
metadata:
  name: alice
spec:
  description: Alice's credentials
  secrets:
    GITHUB_TOKEN: ghp_alice_...
    NPM_TOKEN: npm_alice_...
```

Inline secrets here are convenient for boostrapping but mean the manifest holds plaintext — keep `aod.yml` out of version control or use a per-environment overlay.
