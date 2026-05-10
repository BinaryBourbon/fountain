# Infisical (`infisical://`)

Use the Infisical CLI to resolve `infisical://` references at `fountain apply` time. Fountain calls `infisical secrets get` on your machine — it never sees your Infisical credentials.

## Prerequisites

- An Infisical account (cloud at https://app.infisical.com or self-hosted).
- The `infisical` CLI installed: https://infisical.com/docs/cli/overview

```bash
# macOS
brew install infisical/get-cli/infisical

# Linux
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.rpm.sh' | bash
# or: see https://infisical.com/docs/cli/overview for your distro
```

## Auth

Two options depending on your workflow:

### Interactive (local dev)

Log in once and bind the project:

```bash
infisical login                        # opens browser or prompts credentials
infisical init                         # creates .infisical.json with your project ID
```

After `infisical init`, references using the empty-project form (`infisical:///<env>/<name>`) pick up the project automatically from `.infisical.json`. Run `fountain apply` from the same directory.

### Token-based (CI / headless)

Generate a service token or machine identity token in the Infisical dashboard, then set it before running `fountain apply`:

```bash
export INFISICAL_TOKEN=st.your-token-here...
fountain apply -f fountain.yml
```

Service tokens are scoped to a project + environment, so the project can be omitted from the URI. Machine identity tokens are project-agnostic — include the project ID in the URI.

## URI format

```
infisical://<project-id>/<env>/<name>
infisical://<project-id>/<env>/<folder>/<name>
infisical://<project-id>/<env>/<a>/<b>/<name>    # folder path = /a/b
```

**Empty project** — falls through to `.infisical.json` or `INFISICAL_PROJECT_ID`:

```
infisical:///<env>/<name>
infisical:///<env>/<folder>/<name>
```

| Segment | Description | Example |
|---------|-------------|---------|
| `project-id` | Infisical project ID (UUID or leave empty) | `abc123ef-...` or `` (empty) |
| `env` | Environment slug | `dev`, `staging`, `prod` |
| `folder` (optional) | Folder path, may be multiple segments | `api`, `api/services` |
| `name` | Secret name (always the last segment) | `DATABASE_URL` |

**Find your project ID** in the Infisical dashboard under Project Settings, or:

```bash
infisical projects list
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
    # Explicit project ID
    DATABASE_URL: infisical://abc123ef-1234-5678-abcd-000000000001/prod/api/DATABASE_URL
    REDIS_URL: infisical://abc123ef-1234-5678-abcd-000000000001/prod/api/REDIS_URL

    # Workspace project (from .infisical.json or INFISICAL_PROJECT_ID)
    GITHUB_TOKEN: infisical:///prod/GITHUB_TOKEN
    NPM_TOKEN: infisical:///prod/npm/NPM_TOKEN

---
apiVersion: fountain/v1
kind: Vault
metadata:
  name: alice
spec:
  secrets:
    GITHUB_TOKEN: infisical:///prod/alice/GITHUB_TOKEN
```

### Local dev (interactive auth)

```bash
infisical login
infisical init    # run once in the directory where you'll run fountain apply
fountain apply -f fountain.yml
```

### CI (token auth)

```bash
INFISICAL_TOKEN=st.your-token... fountain apply -f fountain.yml
```

Output:

```
env    +  ravi-hq
  secret  +  ravi-hq/DATABASE_URL
  secret  +  ravi-hq/REDIS_URL
  secret  +  ravi-hq/GITHUB_TOKEN
  secret  +  ravi-hq/NPM_TOKEN
vault  +  alice
  secret  +  alice/GITHUB_TOKEN
```

## Troubleshooting

**`infisical` not on PATH**

```
DATABASE_URL (infisical://...): Infisical CLI (`infisical`) not on PATH — install from https://infisical.com/docs/cli/overview
```

Install the CLI and ensure it's in your `PATH`.

**Not logged in / token expired**

```
DATABASE_URL (infisical://abc123/prod/api/DATABASE_URL): Unauthorized
```

For interactive auth: run `infisical login` again.
For token auth: check `INFISICAL_TOKEN` and regenerate if expired.

**Missing required segments**

```
DATABASE_URL (infisical:///prod): invalid infisical:// reference: expected infisical://<project?>/<env>/<path?>/<name> with at least env and name
```

The URI needs at least `/<env>/<name>`. Add the secret name as the final segment.

**Project not found**

```
DATABASE_URL (infisical://bad-id/prod/DATABASE_URL): Could not find project
```

Verify the project ID in the Infisical dashboard under Project Settings.

**Secret not found in environment/path**

```
DATABASE_URL (infisical:///prod/api/DATABASE_URL): secret not found
```

Check the environment slug and folder path in the Infisical dashboard. Paths are case-sensitive.
