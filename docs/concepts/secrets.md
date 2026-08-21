# Where a secret comes from

This page explains the whole chain, from the key on the server to the string an
agent's process reads. To put a value somewhere, see
[About environments](environment.md) and [About vaults](vault.md). For the
operator side, see
[Back up and restore](../guides/operate/back-up-and-restore.md).

## Four hops

A secret you type into Fountain is transformed four times before an agent sees
it.

```
MASTER_SECRETS_KEY          (the platform key, never in the database)
        |  wraps
        v
per-tenant DEK              (one per user, stored wrapped)
        |  encrypts
        v
the stored value            (AES-256-GCM, at rest)
        |  merged at spawn
        v
environment + vault         (vault wins on collision)
        |  ${VAR} substitution
        v
the process environment     (inside the sandbox)
```

Each hop exists for a different reason, and knowing which one you are looking
at is usually the difference between a five-minute problem and an afternoon.

## Hop 1: the master key wraps a per-tenant key

Every tenant has a data encryption key, a DEK. The DEK is what actually
encrypts that tenant's values.

The DEK is not stored in the clear. It is stored wrapped with AES-256-GCM under
`MASTER_SECRETS_KEY`, in `user_data_keys.wrapped_key`.

`MASTER_SECRETS_KEY` is a 32-byte binary, base64url-encoded, set at runtime.
**It is deliberately not in the database.** That is the whole point of the
arrangement, and it is also why a database backup on its own is useless. See
[Back up and restore](../guides/operate/back-up-and-restore.md).

In dev and test a deterministic key is derived from a fixed phrase. Production
refuses to boot without a real one.

If this shape feels familiar, it is the same one HashiCorp Vault uses. Unseal
key wraps root key wraps keyring wraps data. That analogy holds here, unlike
almost everything else about the word "vault". See
[About vaults](vault.md).

## Hop 2: the DEK encrypts the value

The DEK's lifecycle is short and explicit.

1. At user creation, generate a DEK, wrap it, store it.
2. At conversation start, load the tenant key and unwrap the DEK.
3. While the conversation runs, the unwrapped DEK is held in the conversation
   process's own state, and every encrypt and decrypt is passed it explicitly.
4. When the conversation ends, the DEK is dropped from that state.

Passing the DEK explicitly rather than looking it up is what makes tenant
isolation a property of the call rather than a convention. A function that
needs a DEK cannot accidentally use somebody else's.

Values are write-only from the outside. Listing a vault or an environment
returns keys and timestamps. There is no endpoint that returns a value, for
anyone, including the owner.

## Hop 3: environment and vault merge

At the moment a conversation starts, Fountain resolves the full set.

```
environment secrets  --merge-->  vault secrets  -->  the sandbox
                                       ^
                               wins on collision
```

The merge happens once, at spawn. Editing either afterwards does not reach a
sandbox that is already running.

A conversation may name a different environment than its agent's default, and
may attach a vault, and both are scoped by the agent's
`allowed_environment_ids` and `allowed_vault_ids`.

Non-secret `env_vars` from the environment are merged in too. They are stored
and returned in the clear, so the distinction between `env_vars` and `secrets`
is about who can read the value back, not about who can use it.

## Hop 4: substitution, then the process

Agent config strings support `${VAR}` interpolation, resolved against the
merged map. This is how an MCP server declaration gets a credential without the
credential being written into the agent.

```yaml
mcp_servers:
  github:
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

Substitution is recursive, so it reaches inside maps and lists, and it is
fail-complete. Every missing variable is reported at once rather than one per
attempt, because the alternative is fixing a config one name at a time.

`$$` is a literal `$`.

## What the chain does not do

**No rotation.** Nothing expires a value or tells an agent it went stale.

**No revocation of a live process.** Removing a vault from an agent's
allowlist stops future conversations attaching it. A sandbox already running
keeps what it was given, because by then the value is in a process's
environment on a machine.

**No read audit.** Fountain audits the write, by key and by size, never by
value. It cannot audit the read, because the read happens inside the sandbox.

**No protection against the agent.** Anything in the merged map is readable by
the code running in that sandbox, which is the point of putting it there. Scope
the credential, do not scope the agent.

## Hop 5, which is really a hop back: output is scrubbed

Everything a sandbox writes to stdout or stderr is persisted verbatim into
`log_events` and streamed over SSE. That table has none of the envelope
encryption above, and it outlives the conversation.

So an `env`, a `set -x`, a `cat .env` in a setup script, or an agent that
simply prints its environment would write plaintext credentials into Postgres.
Fountain removes every known secret value from output before it is stored.

Two consequences worth knowing.

**A smoke test that echoes a secret prints `[REDACTED]`.** That is the system
working. Ask for a character count instead if you need to confirm a value
arrived.

**There is a length floor of 8 bytes.** Sandbox environments hold plenty of
short non-secrets, such as `true`, `1`, a port or a region, and redacting those
would turn logs into noise while protecting nothing. The case this misses is a
deliberately short password. Do not use one.

The values live in a registry that the single log writer consults, rather than
being passed to each caller, because the scrubber this replaced was applied on
the HTTPS clone path and not the SSH one. Redaction a caller has to remember
will eventually be forgotten by a new caller.

## Where to go next

- [About environments](environment.md), the baseline half of the merge.
- [About vaults](vault.md), the override half.
- [Back up and restore](../guides/operate/back-up-and-restore.md), because
  hop 1 decides what a backup is worth.
- [Architecture](../architecture.md), for where each piece runs.
