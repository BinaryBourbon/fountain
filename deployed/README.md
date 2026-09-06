# Verify a deployed Fountain

This suite runs outside Fountain against a base URL. It requires Node 24 or
newer and no package install, Elixir application, database connection, or SDK
credential store. The initial `probe` profile checks authenticated identity,
catalog capabilities, liveness and database readiness. The `basic` profile
adds resource CRUD, validation errors, key revocation, tenant isolation, and
an independent check of the instance's advertised response schemas.

The `execution` profile verifies two real tool-using turns on a fresh
ephemeral sandbox. `streaming` adds incremental output, reconnect and replay
conformance to those same two turns. Integration, recovery and browser
profiles remain tracked in #1606. A passing probe does not prove
that conversations work, and selecting an unimplemented profile fails setup.

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

For a real conversation, use two verified accounts and configure inference
credentials on the primary account outside the suite. Select `execution` and
pin its runtime, model and sandbox provider explicitly. This profile creates
its own empty environment and agent and never attaches to an existing sandbox.

```json
{
  "base_url": "https://your-fountain.example",
  "credentials": {
    "primary": "FOUNTAIN_SUITE_KEY",
    "secondary": "FOUNTAIN_SUITE_OTHER_KEY"
  },
  "profiles": ["execution"],
  "execution": {
    "runtime": "claude",
    "model": "anthropic/claude-haiku-4-5",
    "sandbox_provider": "sprites",
    "provision_ms": 120000,
    "turn_ms": 90000,
    "max_turns": 2
  },
  "limits": { "request_ms": 30000, "run_ms": 330000, "cleanup_ms": 90000, "resources": 5 }
}
```

Execution observes provisioning through real SSE, writes a random nonce file
in turn one, reads it in a follow-up, and checks the bytes through the sandbox
file API. Both turns must have durable completion records and persisted tool
activity. It checks the second tenant cannot read the conversation, events,
stream or file, or interrupt/terminate the conversation. It then verifies
terminal conversation/sandbox state before cleanup deletes the transcript and
parent fixtures. Usage and IDs remain in the report after deletion.

The fixture manifest records each prompt attempt **before** sending it. A
lost reply still consumes the two-attempt budget; prompts are never retried
automatically. Provisioning, each turn, the overall run, and cleanup have
separate deadlines. A stream that ends early fails the execution check;
use the `streaming` profile for intentional reconnect/replay assertions. SSE traces record
redacted frames with receive times, and a closed consumer releases its HTTP
connection. Each stream is capped at 4 MiB.

To verify ingress and replay, select `"profiles": ["streaming"]` with the same
explicit execution settings. It includes execution; selecting both is an
error. During turn one, the suite observes output and confirms that the
durable turn record is still running. It then closes the stream, waits for
at least one new persisted event, and reconnects with `Last-Event-ID`.

After turn two, it drains history with a three-event page size and compares
the live/reconnected events and two `wait=false` replay streams against a
fixed durable event prefix. IDs must increase without duplicates; they need
not be consecutive. Matching IDs with different payloads still fail. Events
newer than the completed-turn cursor may arrive while the checks run and do
not change that prefix. The report records the reconnect/missed-event IDs,
comparison counts and pagination evidence. Controlled idle-heartbeat timing
can be added with the deterministic fixture in #1611.

For `basic`, supply two **different** verified test accounts through explicit
environment-variable names. Two keys for the same account fail before any
fixture mutation. This profile includes the probe checks, so select `basic`
alone. Neither account needs inference credentials or a sandbox provider.

```json
{
  "base_url": "http://localhost:4000",
  "credentials": {
    "primary": "FOUNTAIN_SUITE_KEY",
    "secondary": "FOUNTAIN_SUITE_OTHER_KEY"
  },
  "profiles": ["basic"]
}
```

Basic creates an environment, vault, agent, and disposable API key. It verifies
read/update/list/delete behavior, field errors, missing resources, and denied
cross-tenant reads and mutations. The agent uses the built-in Claude runtime
with a model identifier accepted by the API; it is never started. A metadata
update keeps the run-owned name stable for interrupted-run recovery.

Actual responses always validate against the pinned contract. A separate
check compares the advertised operations, statuses and response schema shapes
for the exercised API surface, permitting compatible added properties. It
does not fetch the advertised schema to redefine the expected responses.
Schema failures stay failures; there is no blanket bypass for the broader
schema gaps tracked in #1432 and #1444. The OpenAPI document is summarized by
hash/version rather than copied into response traces. Collection responses
are checked in memory but omitted from traces so existing account resources
and the second tenant's resources do not become suite artifacts.

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

`probe` and `basic` invoke **zero inference turns**. `execution` submits at
most two prompts and records provider-reported usage. It does not enforce a
monetary cap: prompt count and client deadlines are bounded, but model/tool
activity inside a turn and provider charges are not a fixed price. Cleanup
terminates the conversation after failure or cancellation; an unavailable
server/provider can prevent that, which leaves a visible cleanup failure.

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

The runner supports named agent, environment, vault and API-key fixtures,
plus ephemeral conversations linked to its own recorded agent/environment.
Conversation ownership is checked using the run-specific channel ID and both
parent IDs. Cleanup verifies that the sandbox is terminal before deleting the
conversation; it does not use the persistent-sandbox reset endpoint. A failed
conversation cleanup retains its parent fixtures so ownership evidence is not
lost. Keep manifests until every entry is cleaned. A cleanup failure stays
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
