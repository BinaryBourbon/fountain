# About environments

This page explains what an Environment is and why it is separate from the
other three primitives. For every field, see the
[API reference](../api.md). To bootstrap one, see the
[guided tour](../tour.md).

## What an environment is

An Environment is the machine an agent wakes up on, described as data.

It holds four kinds of thing.

- **Encrypted secrets.** Key and value pairs, encrypted per tenant with
  AES-256-GCM. They are write-only. Once stored, the API never returns a value,
  and listing gives you keys and timestamps.
- **Plain environment variables.** A non-secret `env_vars` map for values that
  are not sensitive, such as feature flags and endpoints. The API returns these
  as written, so anything sensitive belongs in secrets instead.
- **Runtime config.** Packages to install, repos to clone, and a setup script
  to run.
- **A networking policy.** `networking_type` is `unrestricted` or `limited`.

## Why it exists

The contents of a machine change on a different schedule from everything else
about an agent.

Python 3.12, a checkout of your service repo and a `mise install` step are
decided once for a team and then left alone for months. Which credentials a
particular run uses can change hourly. Which model an agent runs is revisited
every few weeks.

If those lived in one object, rotating a token would edit the machine image and
every agent sharing it would need a new one. Splitting them means many agents
can share one Environment, and a single run can still deviate from it without
anyone editing the shared thing.

## How it works

An Environment attaches to an Agent when the Agent is created, and that is the
Agent's default.

It is not the only choice. A Conversation may name a different
`environment_id` at launch, scoped by the Agent's `allowed_environment_ids`. So
the same Agent can be provisioned from a heavier image for one task and a
minimal one for another.

At spawn, the Environment's secrets are merged with any attached Vault's
secrets, and the result becomes the process environment inside the sandbox.
The Vault wins on key collision. See [About vaults](vault.md).

```yaml
apiVersion: fountain.dev/v1
kind: Environment
metadata:
  name: python-data-env
spec:
  packages:
    python: "3.12"
  networking_type: limited
  secrets:
    - key: OPENAI_API_KEY
      value: sk-...
```

### The networking policy is not symmetric

`unrestricted` is a no-op. Sprites sandboxes are open by default, so setting it
changes nothing.

`limited` restricts egress to the domains in
`networking_config.allowed_hosts`, which is the only `networking_config` key
honored today.

Under `limited` with no `allowed_hosts`, nothing is allowlisted. That is
deny-all, and it is deliberate rather than a bug. An empty allowlist that
silently meant "allow everything" would be the worst possible default for a
policy whose purpose is restriction.

## What an environment is not

**Not a deployment tier.** "Environment" in Fountain never means dev, staging
or production. Those are things you might build with Environments and Vaults,
not something Fountain models.

**Not a container image.** Fountain does not build or store images. An
Environment is a recipe the sandbox provider applies at provision time, so two
conversations from the same Environment install their packages independently.

**Not a secret store you can read.** Values go in and never come out. If you
need to know what a secret is, you need the source you got it from, not
Fountain.

## When to use something else

Use a [Vault](vault.md) when the value changes per run, per customer or per
credential rotation.

Use `env_vars` rather than `secrets` when the value is not sensitive. The API
returns `env_vars` as written, and a non-secret filed as a secret is a value
nobody can ever read back to check.

Use [inference credentials](../integrations/index.md) for model API keys.
Those are per-user and are never set by an operator or stored in an
Environment.

## Where to go next

- [About vaults](vault.md), the other half of the merge.
- [About agents](agent.md), which names an Environment.
- [The guided tour](../tour.md), which builds one in its first step.
- [Configuration reference](../configuration.md), for the instance-level
  sandbox settings.
