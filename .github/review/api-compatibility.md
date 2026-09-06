# Fountain product and API compatibility review

Review the entire current PR at the supplied head, including original changes
and fixes. Read CONTRIBUTING.md's API sections and relevant ADRs from the supplied
base SHA. Use the service's structured output contract and include every supplied
PR path in coverage. Follow affected behavior through actual source and callers.

For changed controllers, operation declarations, router entries or schemas,
compare the response actually rendered with FountainWeb.ApiSpec and
sdk/contract/contract.json. Required fields, nullable fields, omitted fields,
defaults, errors and enum values are distinct contracts. A schema agreeing with
another schema does not prove a controller renders the promised response.
Inspect schema guardrails and the reasons for any allowlist changes.

Check all affected TypeScript, Python, Elixir and Swift clients, the main Go CLI,
the Buzz CLI module and plugins. Generated TypeScript OpenAPI types and the
committed wire contract must stay current. A new endpoint needs an explicit
client or a justified omission; do not add an omission to make a test pass.
For SSE framing, cursor resume, reconnect, pagination, terminal states, error
mapping and permission flows, inspect shared conformance scenarios and client
adapters. A new skip needs the maintainer's decision, not an automatic fix.

Check public docs, CLI command documentation and examples against the actual
behavior. SDK versions have their own release rules; changing a server contract
does not automatically require publishing every SDK. Never bump versions,
publish a package, add a release-bypass label or alter compatibility manifests
as an automatic way around a failing gate.

Report how an existing caller would break and the evidence for that call shape.
If preserving compatibility requires choosing between product behaviors, mark
needsHuman and explain the alternatives. Evaluate fixes independently from the
fixer's explanation. Your local test output is supporting evidence; the server
owns the required CI and command evidence and final approval.

Apply the maintainer's documented product intent rather than impersonating an
individual. Check names from a caller's perspective, migration and rollout
expectations, CLI/API consistency, and whether the change solves the stated
problem without inventing requirements. Optional wording preferences are low
or info. A blocking finding needs an observable consequence. Product intent
that the approved base does not settle needsHuman, with concrete alternatives.

A fix candidate must preserve public behavior and fit one permitted file with
a clear, high-confidence remedy. Broader changes require a human decision.
Use stable rule and semantic anchor text for recurring findings.
