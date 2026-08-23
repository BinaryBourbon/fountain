# About environments

This page explains what an Environment is, and why it is separate from the
other three primitives. For each field, read the
[API reference](../api.md). To bootstrap one, read the
[guided tour](../tour.md).

## What an environment is

An Environment is the machine an agent wakes on, described as data.

It holds four kinds of thing.

- **Encrypted secrets.** Pairs of key and value, encrypted for each tenant
  with AES-256-GCM. They are write-only. Once you store a value, the API never
  returns it. A list gives you keys and timestamps.
- **Plain environment variables.** A non-secret `env_vars` map, for values
  that are not sensitive. Feature flags and endpoints go here. The API returns
  these as you wrote them, so a sensitive value belongs in secrets instead.
- **Runtime config.** The packages to install, the repos to clone, and the
  setup script to run.
- **A network policy.** `networking_type` is `unrestricted` or `limited`.

## Why it exists

What a machine holds changes on a different schedule from everything else
about an agent.

A team decides Python 3.12, a checkout of your service repo and a
`mise install` step one time, then leaves them alone for months. Which
credentials one run uses can change each hour. Which model an agent runs is a
question you revisit every few weeks.

Put those in one object, and a token rotation edits the machine image. Each
agent that shares the image then needs a new one. Divide them, and many agents
can share one Environment. A single run can still deviate from it, and nobody
edits the shared thing.

## How it works

You attach an Environment to an Agent when you create the Agent. That
Environment is the Agent's default.

It is not the only choice. A Conversation can name a different
`environment_id` at launch, within the Agent's `allowed_environment_ids`. So
the same Agent can start from a heavy image for one task and a small one for
another.

At spawn, Fountain merges the Environment's secrets with the secrets of any
attached Vault. The result becomes the process environment in the sandbox. The
Vault wins on a key collision. Read [About vaults](vault.md).

```yaml
apiVersion: fountain.dev/v1
kind: Environment
metadata:
  name: python-data-env
spec:
  packages:
    apt:
      - jq
  networking_type: limited
  secrets:
    OPENAI_API_KEY: sk-...
```

`secrets` must be a map of `KEY: value`. The server keeps only the map form
and drops any other shape without an error. The map form is also what the
CLI's `${VAR}` substitution and secret-manager references resolve against.
`packages` has two keys that install software, `apt` and `npm`. Other
language toolchains go in `setup_script`.

### The network policy is not symmetric

`unrestricted` does nothing. A Sprites sandbox is open by default, so the
value changes nothing.

`limited` holds egress to the domains in `networking_config.allowed_hosts`.
That is the only `networking_config` key Fountain reads today.

Under `limited` with no `allowed_hosts`, the allowlist is empty. Nothing gets
out. That is deliberate, and it is not a defect. An empty allowlist that
quietly meant "allow everything" would be the worst default for a policy whose
whole purpose is restriction.

Not every backend can hold egress. Sprites, E2B and Daytona can. A
[self-hosted runner](../integrations/runners.md) cannot. The agent selects the
backend, and the environment sets the policy. Fountain therefore compares the
two at launch. It refuses a `limited` environment on a backend that cannot
enforce one. The conversation fails with a `network` / `failed` event. The
reason is `backend_lacks_network_policy`, and Fountain creates no sandbox. The
agent form gives you the same warning before you save the agent.

## What an environment is not

**Not a deployment tier.** "Environment" in Fountain never means dev, staging <!-- vale disable-line STE.IngForms -->
or production. You might build those out of Environments and Vaults. Fountain
does not model them.

**Not a container image.** Fountain builds no image and stores no image. An
Environment is a recipe that the sandbox provider applies at provision time.
Two conversations from the same Environment install their packages
one by one, on their own machines.

**Not a secret store you can read.** Values go in and never come out. To learn
what a secret is, go back to the source you got it from. Fountain will not
tell you.

## When to use something else

Use a [Vault](vault.md) when the value changes for each run, for each customer
or at each credential rotation.

Use `env_vars` and not `secrets` when the value is not sensitive. The API
returns `env_vars` as you wrote them. File a non-secret as a secret, and you
get a value that nobody can ever read back to check.

Use [inference credentials](../integrations/index.md) for model API keys.
Those belong to one user. An operator never sets them, and an Environment
never stores them.

## Where to go next

- [About vaults](vault.md), the other half of the merge.
- [About agents](agent.md), which names an Environment.
- [The guided tour](../tour.md), which builds one in its first step.
- [Configuration reference](../configuration.md), for the sandbox settings
  that belong to the instance.
