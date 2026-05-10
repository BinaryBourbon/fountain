# Secrets managers

`fountain apply` resolves secret values at apply time — before writing anything to the database — so you can commit `fountain.yml` without embedding credentials.

Any value under `spec.secrets` can be a URI reference. The resolver for each scheme runs on the operator's machine using its own CLI and credentials. Fountain never sees your vault password or access token.

## URI schemes

| Scheme | Format | Auth |
|--------|--------|------|
| `op://` | `op://<vault>/<item>/<field>` | `op` session / biometric |
| `bws://` | `bws://<secret-uuid>` | `BWS_ACCESS_TOKEN` env var |
| `infisical://` | `infisical://<project?>/<env>/<path?>/<name>` | `INFISICAL_TOKEN` or `infisical login` |
| `${VAR}` | `${MY_ENV_VAR}` | operator shell / `--var` flag |

## Composing references

`${VAR}` substitution runs first, so you can build dynamic URIs:

```yaml
secrets:
  ANTHROPIC_API_KEY: op://${OP_VAULT}/Anthropic/key   # ${OP_VAULT} → substituted, then op resolves
```

Use `$${VAR}` to write a literal `${VAR}` (escapes the substitution).

## Example manifest

```yaml
---
apiVersion: fountain/v1
kind: Environment
metadata:
  name: my-project
spec:
  secrets:
    GITHUB_TOKEN: ${GH_PAT}                                 # from $GH_PAT in shell
    POSTHOG_API_KEY: op://Work/PostHog/api_key              # 1Password
    NPM_TOKEN: bws://11111111-1111-1111-1111-111111111111   # Bitwarden Secrets Manager
    DATABASE_URL: infisical://abc123/prod/api/DATABASE_URL  # Infisical (explicit project)
    REDIS_URL: infisical:///prod/REDIS_URL                  # Infisical (workspace project)
---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  secrets:
    GITHUB_TOKEN: op://Personal/GitHub/token
```

Run:

```bash
GH_PAT=ghp_... ./fountain apply -f fountain.yml
# or: ./fountain apply -f fountain.yml --var GH_PAT=ghp_...
```

## Failure output

Both resolution phases collect all failures before aborting, so you fix everything in one pass:

```
apply-time substitution failed — set these in the env or pass --var KEY=VAL:
  my-project: GH_PAT

apply-time secret resolution failed:
  my-project:
    POSTHOG_API_KEY (op://Work/PostHog/api_key): [ERROR] ... session expired
    NPM_TOKEN (bws://be8e0ad8-...): Error: invalid access token
```

## Per-tool guides

- [1Password](secrets/1password.md)
- [Bitwarden Secrets Manager](secrets/bws.md)
- [Infisical](secrets/infisical.md)

## Scope

Apply-time resolution is scoped to `spec.secrets` only. Other manifest fields (agent system prompts, `mcp_servers` command args, etc.) use the provision-time substitution layer — same `${VAR}` syntax, different scope.
