# Verify a deployed Fountain

This suite runs outside Fountain against a base URL. It requires Node 24 or
newer and no package install, Elixir application, database connection, or SDK
credential store. The initial `probe` profile checks authenticated identity,
catalog capabilities, liveness and database readiness.

The execution, integration, recovery and browser profiles in tracker #1606
are not implemented yet. A passing probe does not prove that conversations
work, and selecting an unimplemented profile fails setup.

## Run

Provision a dedicated verified test account on your instance and mint its
full-scope API key outside the suite. Registration can remain disabled. Put
the key in `FOUNTAIN_SUITE_KEY` through your local environment or CI secret
store; the suite does not search your home directory or log credential values.

Copy `deployed/target.example.json` to a local target file and set `base_url`.
Each run requires a new output directory; its parent must already exist.

```bash
node deployed/cli.mjs run --config /tmp/fountain-target.json --out /tmp/fountain-run-001
```

The default expected wire contract is `sdk/contract/contract.json` from the
suite checkout. Pin the checkout to the release you intend to verify, or set
`contract` to another versioned projection file, relative to the target file.
The result records its SHA-256. This is a structural validator for Fountain's
version-1 projection: primitive types, required fields, nullable fields, enums,
arrays, references, unions and additional-property rules. It does not claim
full OpenAPI validation of formats, numeric bounds or string patterns. It
permits compatible added fields unless the contract explicitly forbids them.

`required_capabilities` names runtimes and sandbox providers the deployment
must advertise. Declare these from your intended configuration, independently
of discovery. A required provider disappearing fails setup. An optional entry
has a `name` and `reason`; an absent optional capability is recorded as skipped.
No configured sandbox is needed for `probe`.

```json
{
  "required_capabilities": { "runtimes": ["claude"], "sandbox_providers": [] },
  "optional_capabilities": {
    "sandbox_providers": [{ "name": "sprites", "reason": "Not configured on this local fixture" }]
  }
}
```

## Results and limits

Every initialized run writes `result.json` and `junit.xml`, with check durations
and failures. `http.jsonl` contains bounded JSON response evidence and request
IDs; headers carrying credentials and request bodies are not recorded. Known
credentials and secret-shaped response fields are redacted. Non-JSON bodies
are rejected without recording their raw contents. Output directories are
private and new artifact files use mode `0600`.

| Exit | Meaning |
|---|---|
| 0 | Every required check passed; cleanup completed |
| 1 | Assertion, run deadline, or runtime failure |
| 2 | Invalid configuration, missing credentials, identity/capability setup failure |
| 3 | Cleanup failed or a creation intent remains unresolved |
| 130 | Interrupted; inspect the report and cleanup manifest |

Checks and fixture creation are sequential. `limits` bounds request duration
(including response bodies), the overall run, the separate cleanup window,
and the number of created resources. HTTP responses are capped at 2 MiB and
redirects are not followed. SIGINT/SIGTERM cancel requests and then allow the
bounded cleanup pass. SIGKILL cannot run cleanup.

The initial profiles invoke **zero inference turns**. They therefore do not
estimate or enforce a monetary budget. Future execution profiles must account
for accepted turns and runtime and distinguish any configured monetary
estimate from a provider-enforced hard limit before invoking inference.

The result explicitly reports that deployment revision is unverified. A URL
and a successful response do not establish image identity. Confirmed rollout
integration and deployment revision adapters belong to #1612.

## Interrupted runs and cleanup

`cleanup.json` binds run-owned fixtures to the normalized target URL, verified
account ID and a random run ID. A creation intent is saved before its POST;
the returned ID is saved before contract assertions. Cleanup uses only the
supported resource kinds and verifies the exact run-owned name before deletion.
It never deletes an account or discovers resources by a broad name prefix.

```bash
node deployed/cli.mjs cleanup --config /tmp/fountain-target.json \
  --manifest /tmp/fountain-run-001/cleanup.json --out /tmp/fountain-cleanup-001
```

Use the same target and account. Cleanup has its own deadline, tolerates
already deleted resources, and runs in reverse creation order. A lost create
response can be reconciled by an exact unique name. When an intent has no
visible match, it remains unresolved: the original request may still commit.
Retry cleanup after the server settles and investigate a persistently
unresolved intent; absence at one instant is not proof of successful cleanup.

The foundation supports named agent, environment, vault and API-key fixtures.
Conversation/sandbox lifecycle cleanup will be added with the execution
profile. Keep manifests until every entry is cleaned. A cleanup failure stays
visible even when the assertions themselves passed.

## Develop the suite

```bash
node --test deployed/test/*.test.mjs
```

These tests use loopback HTTP servers to exercise harness failures; they are
not evidence that a deployed Fountain conforms. Live verification runs the
CLI against a released image or an explicitly configured remote test instance.
The normal CI checks run the harness tests without live credentials.

Add profiles as ordinary modules using `ctx.check`, `ctx.client`, and
`ctx.fixtures`, with assertions against public responses. Register them in
`lib/runner.mjs`. Mutations must record cleanup intent before sending a create
request. Do not inject database rows, import server factories, or substitute
an in-process Fountain for a deployed verdict. Existing SDK conformance
remains separate and runnable with its existing commands.
