# Console browser profile

This is the console portion of #1618. It is under development and has no complete
profile verdict yet. A manual local Chrome check verified sign-in, agent creation
and editing, and empty credential validation with registration disabled. The
pinned Playwright driver and key lifecycle still need a complete live run.
The profile is never selected by default or by rollout canaries.

Install the pinned dependency with `npm ci --prefix deployed/browser`, then
install its Chromium build with
`deployed/browser/node_modules/.bin/playwright install chromium`.
Copy `deployed/browser.example.json` and set its target and environment variable
names. Run it with the ordinary deployed suite CLI described in the parent
README. The existing cleanup command handles a stopped browser run's manifest.
It retains an unresolved creation intent when no matching row exists: absence
alone cannot prove that an in-flight submission will never commit. Reconcile a
known rejected submission separately before marking that intent canceled.

The API key and the email/password must belong to the same dedicated, verified
test account. The profile signs in through the console; it does not depend on
registration being enabled. A fresh browser context prevents reuse of another
person's signed-in session. The run creates at most two resources and makes no
inference calls.

The journey creates and edits an agent through the console, verifies it through
the public owner API, creates a key through the console, authenticates with that
key, revokes it through the console, and requires a 401 from the revoked key.
Each creation intent is saved before clicking. A lost reply leaves an exact
run-owned name for the standard cleanup command to recover.

Credential coverage currently checks that the selected provider's input masks
its value and an empty submission produces validation feedback without changing
provider status. It does **not** claim successful provider validation or storage
of a valid credential. That part of #1618 remains unfinished.

Evidence is an allowlisted `browser.jsonl` action/response trace plus cropped
static-heading screenshots. Native Playwright traces, videos, HAR, DOM dumps,
console messages and raw errors are excluded because they can contain passwords,
keys, cookies and OAuth codes. Error reports identify the failing named step.
Screenshots never capture the one-time key reveal. Debug tracing environment
variables are rejected before entering credentials.

The Conversations app handoff, OAuth/CORS checks and isolated fresh-Compose
registration case remain unfinished. Configuration requires `conversations:
null` until the handoff implementation exists, so configuring an app cannot
silently yield a passing app verdict. The app source is maintained separately in
`jhgaylor/fountain-conversations`; report app rendering, routing and client
authentication defects there with the exact source and served asset hashes.
Report server cookies, OAuth registration, CORS and console failures in Fountain.
Broad app UI permutations belong in that app's own suite.
