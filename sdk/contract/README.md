# The SDK wire contract

One API, four clients. The server is the only place the API is described, and
this directory is how that description reaches TypeScript, Python, Swift and
Elixir so a schema change fails in the PR that makes it rather than months
later in somebody's application.

## The three files

| File | Written by | Checked in |
|---|---|---|
| `../../dist/openapi.json` | `mix openapi.export`, canonicalised by `scripts/sdk-contract/build.py` | no — `dist/` is ignored |
| `contract.json` | `scripts/sdk-contract/build.py` | yes |
| `manifests/<sdk>.json` | a person | yes |

`dist/openapi.json` is the whole OpenAPI document with vendor extensions off.
It moves with every prose edit and every release, which is why it is rebuilt
rather than committed.

`contract.json` is that document projected down to shape alone: operations,
schemas, requiredness, enums, formats, nullability. Descriptions, summaries,
tags and `info.version` are dropped, so a docs pass or a version bump leaves
this file byte-identical and a diff on it means exactly one thing — the wire
changed. It is committed so an SDK check needs no Elixir toolchain: the Swift
job on macOS reads it straight from the checkout.

`manifests/<sdk>.json` is what one client says it depends on. Each SDK has a
verifier in its own language that reads both files and fails, naming itself and
the scenario, when the two disagree.

## Rebuilding

```bash
scripts/sdk-contract/build.sh          # rebuild the artifact and the contract
scripts/sdk-contract/build.sh --check  # rebuild, then fail if the contract is stale
```

The export boots the app, so it needs Elixir and a database URL. Everything
downstream of it does not.

Determinism is not left to the encoder. `build.py` sorts every object key
recursively before writing either file, so the output depends on the document
and nothing else — not on Jason's map ordering, not on the OTP release. Run it
twice from a clean checkout and the second run writes the same bytes.

## The manifest

```jsonc
{
  "sdk": "python",
  "operations": ["GET /api/agents", "POST /api/conversations"],
  "schemas": {
    "Turn": {
      "required": ["id", "turn_number", "status"],  // read as always present
      "optional": ["ended_at"],                     // the client may omit it
      "fields": ["exit_code", "prompt"]             // read, requiredness not relied on
    }
  },
  "enums": {
    "Turn.status": ["completed", "failed"],
    "LogEvent.kind": { "values": ["output", "stage"], "exhaustive": true }
  }
}
```

What each verifier checks, in the same order, with the same messages:

1. **Operations.** Every `"METHOD /path"` still exists. A moved, renamed or
   deleted endpoint fails here.
2. **Schemas.** Every named schema still exists.
3. **Fields.** Every name under `required`, `optional` and `fields` is still a
   property of its schema. A renamed field fails here, and the message lists
   the properties the schema does have.
4. **Requiredness.** A `required` name must still be required; an `optional`
   name must still be optional. On a response schema that reads as "the client
   takes this field without a guard" and "the client copes when it is absent".
   On a request schema it reads as "the client always sends this" and "the
   client leaves this out when the caller gave nothing", which is the check
   that guards the `default` trap below.
5. **Enums.** The declared values must still be accepted. An entry written as
   a bare list is a subset check: the client handles these, the API may add
   more. `{"values": [...], "exhaustive": true}` demands equality, for the
   places where a new value would fall through a `switch` — declare it only
   where the client genuinely enumerates every case.

A response envelope is not a special case. `AgentListResponse` is a schema with
one required property, `data`; declare it and a server that renames the
envelope key fails check 3.

## The omissions allowlist

`omissions.json` records the operations no SDK's hand-written layer models, one
reason per group. `build.py --check` fails when an operation is neither claimed
by a manifest nor matched here, **and** when an entry here matches nothing the
API still serves. So a new endpoint stops CI until somebody decides — wire it
into a client, or write the line saying why no client needs it. Deleting an
endpoint that was written down here fails too, rather than leaving a stale
reason behind.

Patterns are fnmatch globs over `METHOD /path`, with the path exactly as the
OpenAPI document templates it (`/api/agents/{id}`, not `/api/agents/:id`).

## What this does not catch

A manifest is a declaration, not a derivation. If a client starts reading a
field and nobody adds it to the manifest, the rename that breaks it later will
not fail here. Adding the field to the manifest is part of writing the code
that reads it — the same way a new endpoint gets a test.

The complement is `sdk/typescript`, which generates types for the *whole*
document into `src/generated/openapi.ts` and fails on a diff. Between the two,
every schema in the API is pinned somewhere, and the fields the ergonomic
layers actually reach for are pinned in all four languages.

## The `default` trap

An OpenAPI property that carries a `default` is **not** required — the default
is what the server uses when the client omits it. `openapi-typescript` emits
such a property as non-optional anyway, which is why
`sdk/typescript/src/schemas.ts` re-relaxes `ScheduleInput`.

The projection takes requiredness from the schema's `required` list and nothing
else, records `has_default` separately, and `build.py` refuses to write a
contract where a default-carrying property came out required. Four properties
are in that state today (`ChatCompletionRequest.stream`,
`InferenceCredentialRequest.validate`, `TeamScheduleCreateRequest.enabled`,
`TeamScheduleCreateRequest.one_off`); the TypeScript manifest declares the last
two as `optional`, so the day the server makes one required, the client that
omits it is told.

## Per-SDK commands

| SDK | Command | Run from |
|---|---|---|
| TypeScript | `npm run verify-contract` | `sdk/typescript` |
| TypeScript (types) | `npm run generate` then check for a diff | `sdk/typescript` |
| Python | `python3 scripts/verify_contract.py` | `sdk/python` |
| Swift | `swift test --filter ContractTests` | repository root |
| Elixir | `mix test test/contract_test.exs` | `sdk/elixir` |

`CONTRIBUTING.md` has the order to run them in when a PR changes the API.
