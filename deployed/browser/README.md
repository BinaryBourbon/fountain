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
person's signed-in session. A console-only run creates at most two resources and
makes no inference calls. The optional app journey requires four resources and
an explicit two-prompt budget.

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

## Conversations handoff

Use `deployed/browser-app.example.json` for the optional app journey. Its bundle
lock was built from Conversations revision
`862552d8ece9abef20535e9b9c0b19821bf614c4` with that repository's frozen dependency
lock. Build and host that revision, or replace the lock with the exact build you
intend to test. Keep the build's source revision and dependency/build evidence.

Generate a lock from the app's built `dist` directory with:

```sh
node deployed/browser/lock-app.mjs \
  --root /absolute/path/to/dist \
  --url https://conversations-staging.example.com/ \
  --revision 862552d8ece9abef20535e9b9c0b19821bf614c4 \
  --out /tmp/conversations-lock.json
```

Copy that JSON object into `browser.conversations.lock`. Set Fountain's
`CONVERSATIONS_APP_URL`, `API_CORS_ORIGINS` and the `fountain-conversations`
entry in `OAUTH_CLIENTS` to the same app URL/origin. The exact redirect URI is
the app URL with its trailing slash. The suite does not change those settings.
The app and Fountain must have distinct origins. HTTPS is required except for
local loopback fixtures.

The preflight checks each served asset against the lock. Browser routing then
checks the bytes the browser actually receives, including the entry page, and
refuses unpinned app resources, redirects, and third-party app requests outside
the configured Fountain API. Service workers are blocked. The fixture must
honor identity content encoding so verified bytes can be delivered with their
original headers. OAuth denial permits one callback with the expected state;
query parameters and state never enter the evidence trace. Debug source maps
are excluded from the fixture.

The journey provisions a conversation with the UI-created agent, follows
Fountain's `/conversations/:id` redirect, checks the app's PKCE authorization
request, and denies consent. It then signs in through the app's supported key
entry flow using the run-owned UI key. Both artifact prompts are sent through
the composer. Public turn/history/file checks independently require exactly
two accepted turns, tool use, exact nonce bytes, and full/cursor replay. The
second assistant reply must visibly render the nonce in the app. Browser
request origins, CORS responses, and consumed app responses are checked. After
app sign-out, the console revokes that exact key and the public API must reject
it with 401.

This path verifies OAuth denial and API-key authentication. It does not verify
a successful OAuth grant. A complete authenticated live handoff verdict,
valid provider credential save/clear, successful OAuth authorization, and the
isolated fresh-Compose registration case remain unfinished under #1618.

The app source is maintained separately in
`jhgaylor/fountain-conversations`; report app rendering, routing and client
authentication defects there with the exact source and served asset hashes.
Report server cookies, OAuth registration, CORS and console failures in Fountain.
Broad app UI permutations belong in that app's own suite.
