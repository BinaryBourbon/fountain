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

The default credential check requires a masked input and empty-submission
feedback without changing provider status. To exercise valid setup, add
`browser.credential_setup` with the following settings and provide the value
through the named environment variable.

```json
{
  "mode": "save_and_clear",
  "exclusive_account": true,
  "value": "FOUNTAIN_BROWSER_PROVIDER_KEY"
}
```

Reserve this test account exclusively until cleanup finishes. This setting is
an operator assertion, not a server lock. The provider status API exposes no
revision or compare-and-swap operation, so this mode cannot safely share an
account with another writer. An already-set provider is refused. Increase the
resource budget to three for console checks or five for the app journey.

Setup runs before agent creation. It submits the supplied value once, requires
the console's successful provider-validation message and public set status,
and leaves the credential available during the optional app prompts. At the
end, the console clears it and the API must report unset. Failure cleanup uses
the public DELETE endpoint. The manifest records provider, initial unset state,
account reservation and progress; it never records the value. An unset provider
with an unresolved save intent remains pending because the save could still
commit. Keep the account reserved until that submission is reconciled.
This path has automated cleanup tests but still needs live browser validation.

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
live provider credential save/clear and successful OAuth authorization remain
unverified. The isolated bootstrap case is described below.

The app source is maintained separately in
`managoat/demos`, under `apps/fountain-conversations`; report app rendering, routing and client
authentication defects there with the exact source and served asset hashes.
Report server cookies, OAuth registration, CORS and console failures in Fountain.
Broad app UI permutations belong in that app's own suite.

## Fresh Compose bootstrap

First-account registration runs separately from the existing-instance profile.
It requires no preexisting account or API key. Copy this configuration, replace
the image placeholders with registry digests and select a local Docker context.
Pull both exact image references before starting the case.

```json
{
  "app_image": "ghcr.io/managoat/fountain@sha256:REPLACE_WITH_DIGEST",
  "postgres_image": "postgres@sha256:REPLACE_WITH_DIGEST",
  "context": "orbstack",
  "port": 14826
}
```

Use the same pinned browser dependency installed above.

```sh
node deployed/browser/bootstrap.mjs run \
  --config /absolute/path/to/bootstrap-target.json \
  --out /tmp/fountain-bootstrap-run
```

The output directory must be new. The case resolves this repository's Compose
file without the operator's environment or service credentials. It records that
source file's hash and each image's identity, including the app source revision.
It runs the stock app and Postgres services with generated local encryption
secrets, no email delivery, registration enabled and first-admin bootstrap on.
These settings apply only to its new project. External app links are disabled.

Each project gets a unique network and database volume. The app publishes only
the selected loopback port; Postgres publishes no port. Before browser work,
the adapter checks actual image identities and port bindings, host health and
readiness responses, and an empty user/key database. A local Unix-socket Docker
endpoint is required. The ordinary bridge network permits the host connection;
this case does not claim an outbound network sandbox.

The browser creates one synthetic account, signs in, opens Admin, signs out,
and requires a subsequent Admin navigation to redirect to login. A fixed
read-only database query independently requires exactly one verified admin and
zero API keys. Evidence uses named browser steps and a static Admin-heading
crop. No inference calls or API-key creation are part of this case.

Cleanup checks the Docker endpoint, Compose configuration hash and both project
and run labels before removing the containers, network and database volume.
It verifies that no resources remain, then removes generated secret files.
If interrupted, preserve the private output directory and run the following.

```sh
node deployed/browser/bootstrap.mjs cleanup --out /tmp/fountain-bootstrap-run
```

For an interactive browser check, use `prepare` in place of `run`. This leaves
the verified fresh fixture running and prints its local URL. Run cleanup after
the browser check. Never expose that fixture beyond loopback or reuse its
account as an existing-instance test account.

Local Chrome exercised registration, sign-in, first-admin access and sign-out
against the Compose-pinned v0.16.0 image. Database counts confirmed one verified
admin and zero keys; cleanup removed all four Docker resources. An initial
Admin-heading lookup timed out in the browser transport. Subsequent DOM
inspection verified the page, and the original timeout remains in the evidence.
The standalone Playwright bootstrap driver still needs its own live verdict.
