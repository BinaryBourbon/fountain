# Changelog

Notable changes to `@agentshit/fountain-sdk`. Format:
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[SemVer](https://semver.org/).

The SDK versions independently of the Fountain server. It talks to the REST
API, which is additive, so a given SDK release keeps working against later
server releases.

---

## [0.1.1] — 2026-08-23

No code change from 0.1.0. This is the first release published by CI through
npm's trusted publishing, so unlike 0.1.0 — which went out from a laptop — the
tarball carries a provenance attestation tying it to the workflow, the
repository and the commit that built it. Verify with `npm audit signatures`.

## [0.1.0] — 2026-08-23

First published release.

### Added

- `fountain.run(prompt, { agent, vault, environment })` — one call that
  provisions a sandbox, runs the agent in it and folds the log feed into an
  answer. `await` it, `for await` it, or read `.textStream`; all three are
  views of one run.
- `fountain.resume(id)` — the sandbox and the agent's session are still there,
  so a follow-up costs one prompt rather than a re-explanation.
- `agents`, `environments`, `vaults` — list, read, create, update, delete, and
  write-only secrets. All of them take a **name** where an id would do.
- `team` — teammates, their standing threads, and their routines.
- Streams that reconnect from a cursor, so a deploy mid-turn neither drops the
  answer nor replays it.
- Errors keyed on the API's `error` code rather than the status, because
  `conversation_busy` is a 400, `sandbox_quota_exceeded` a 429 and
  `provisioning` a 503, and what a caller does about each is unrelated to the
  number. Every error carries `retryable`.
- `run.answer(requestId, optionId)` and `resume(id).answer(...)`, with a
  `{ type: "permission" }` run event, for agents whose `permission_policy` has
  an `ask` entry.
- Types generated from the server's own OpenAPI document, with CI failing on
  any drift between the two.
- A browser entry with no Node built-in reachable from it, and a Node entry
  that adds `~/.fountain/credentials`.

[0.1.1]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/0.1.1
[0.1.0]: https://www.npmjs.com/package/@agentshit/fountain-sdk/v/0.1.0
