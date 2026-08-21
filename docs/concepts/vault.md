# About vaults

This page explains what a Fountain Vault is, why it exists, and why it is not
the thing its name suggests. For every field, see the
[API reference](../api.md). For the commands, see the
[CLI reference](../cli.md).

## If you have used HashiCorp Vault, read this first

The names collide and the meanings are close to opposite. Getting this
backwards produces exactly the wrong model of how a credential reaches a
sandbox, so it is worth thirty seconds.

| HashiCorp Vault | Fountain Vault |
|---|---|
| One central server you deploy, cluster and unseal | A small record in Fountain's database. Make as many as you like |
| The authoritative store. If it is in Vault, it is true | A patch layer. The Environment is the baseline and the Vault overrides it |
| Issues dynamic, leased, revocable credentials | Holds static values you wrote. No leases, no rotation, no revocation |
| Sealed until an operator unseals it | No state. There is nothing to unseal |
| Path mounts and per-path policy | A flat key and value bag, scoped to your tenant |
| Precedence is not a concept | Precedence is the entire point |

One thing does carry over. Both encrypt with an envelope. HashiCorp goes unseal
key, then root key, then keyring, then data. Fountain goes
`MASTER_SECRETS_KEY`, then a per-tenant data encryption key, then the value. If
you understood theirs, you already understand
[ours](../architecture.md).

## What a vault is

A Vault is a named bag of environment variable overrides that layers over an
Environment for one run.

It is free-floating. It belongs to no Agent and no Environment. It can be
attached to any conversation the Agent's `allowed_vault_ids` permits, and the
same Vault can be attached to conversations of different Agents at the same
time.

```yaml
apiVersion: fountain.dev/v1
kind: Vault
metadata:
  name: staging-creds
spec:
  secrets:
    - key: DATABASE_URL
      value: postgres://staging-host/mydb
```

## Why it exists

Without vaults, changing one credential means editing the Environment, and the
Environment is shared. Three consequences follow, and teams hit all three.

Running one Agent against staging and production would need two Environments
that are identical except for one URL. They would drift.

Giving a contractor's agent a scoped token would mean either widening the
shared Environment or cloning it.

Rotating one key would touch every agent using that Environment, whether or not
they use the key.

A Vault makes each of those a one-line attachment on a single run and leaves
the shared thing alone.

## The merge rule

When a Conversation starts, Fountain builds the environment variable set in one
direction.

```
environment secrets  --merge-->  vault secrets  -->  the sandbox
                                       ^
                               wins on collision
```

The Vault wins. If the Environment sets `DATABASE_URL` and the attached Vault
also sets `DATABASE_URL`, the process sees the Vault's value.

The merge happens once, at spawn. Editing a Vault does not reach a sandbox that
is already running.

Keys that only the Environment sets survive untouched. A Vault is a patch, not
a replacement.

## What a vault is not

**Not rotation.** A value you put in a Vault stays there until you change it.
Fountain does not expire it, does not renew it and does not tell an agent that
it went stale.

**Not revocation.** Removing a Vault from an Agent's `allowed_vault_ids` stops
future conversations attaching it. A sandbox that is already running keeps the
value it was given, because by then the value is in a process's environment on
a machine.

**Not a read audit.** Fountain audits the mutation when a secret is written, by
key and by size. It does not record that an agent read one, because the read
happens inside the sandbox.

**Not returnable.** Values are write-only. Listing a Vault returns keys and
timestamps. There is no endpoint that gives you a value back, including as the
owner.

## When to use something else

Use an [Environment](environment.md) for anything the whole team shares that
changes rarely.

Use `env_vars` on an Environment for values that are not sensitive. A Vault
holding one non-secret is a Vault someone will later assume is secret.

Use [inference credentials](../integrations/index.md) for model API keys.
Those are per-user, entered in the running app, and never belong in a Vault.

## What we chose not to do

We considered per-key precedence, so a specific Environment key could refuse to
be overridden by a Vault. We rejected it. A merge rule that holds always is
worth more than a merge rule that is more expressive, because the reader has to
hold it in their head at the moment they are debugging a wrong credential,
which is usually a bad moment.

We also considered making the Vault the baseline and the Environment the
override, which would have matched the HashiCorp prior. We rejected it because
the thing that changes rarely should be the base.

## Where to go next

- [About environments](environment.md), the other half of the merge.
- [About agents](agent.md), which decides which vaults are attachable.
- [Architecture](../architecture.md), for the full encryption chain.
- [CLI reference](../cli.md), for `fountain vault`.
