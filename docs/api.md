# API reference

Use the [generated API reference](/api/docs) for endpoints, parameters,
request bodies, response schemas, and error statuses. Fountain builds that
reference from the same OpenAPI descriptions that define its SDK contract.
The [OpenAPI document](/api/openapi.json) is public and needs no credential.

The reference describes the instance that serves it, with its installed
extensions. On a self-hosted instance, open `/api/docs` on that instance.
This guide explains workflows; it does not maintain a second endpoint catalog.

For a script, start with the [TypeScript](sdk.md), [Python](python-sdk.md),
[Elixir](elixir-sdk.md), or [Swift](swift-sdk.md) SDK. Use HTTP directly when
your language or workflow needs a surface the SDK does not expose.

## Authentication

Create an API key in the console under Account, then API keys. Store it
outside your source tree. Pass the key as a bearer token.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  "$FOUNTAIN_URL/api/agents"
```

Set `FOUNTAIN_URL` to your instance URL, without a slash at the end.
Use `fountain auth login` for a password account, or
`fountain auth login --device` for an account that uses GitHub sign-in.
Reuse that credential; repeated token exchanges create more keys.

Check the Auth operations in the [generated reference](/api/docs) for
account recovery, verification, key creation, revocation, and credential
expiry. A sandbox credential has restricted scope. Use an account credential
for administrative workflows.

### Sign in with Fountain (OAuth 2.0 for browser apps)

Browser apps use the authorization code flow with PKCE. The returned token
is a Fountain API key. Register the client and its exact redirect URIs with
the instance operator before you start the flow.

Keep the verifier in the app that initiated sign-in, and validate `state`
on return. See [Build a team chat](build/team-chat.md) for an application
example and the OAuth operations in the [generated reference](/api/docs)
for the token exchange.

## Account state

Read account identity before you display account-specific controls. The console
uses onboarding state to show setup progress. An API integration can complete
setup without following the console checklist.

See the account and Auth operations in the [generated reference](/api/docs).

### Billing

Hosted work spends a credit balance. An idle machine does not burn turn
credits. Check the account's available balance before you offer a workflow
that starts paid work, and handle a refusal when admission occurs.

See [Billing](guides/operate/billing.md) for operation and
[Sandbox spend](guides/operate/sandbox-spend.md) for the distinction between
turn usage and provider usage. The [generated reference](/api/docs) describes
account balances, purchases, and payment errors.

### Data export and deletion

Export account data before you delete an account if you need an archive.
Treat deletion as a separate, explicit user action. See the account operations
in the [generated reference](/api/docs) for the export and deletion contracts.

## Inference credentials

Inference credentials pay the model provider. Fountain credits pay for
Fountain's hosted work. Configure both when the selected runtime needs them.
A configured credential does not imply that a provider will accept it.

See [Vaults](concepts/vault.md) and the account credential operations in the
[generated reference](/api/docs). Read responses describe credential state;
secret values remain write-only.

## Claimable principals

A claimable principal lets an application start a computer before its visitor
has a Fountain account. A claim attaches an owner; resource IDs and the
tenant stay the same.

Follow [Start before sign-in](build/anonymous-visitors.md). Use the documented
idempotency key to reconcile a lost create or claim response. A repeated
request can return a fresh credential, so keep the latest successful result.
The [generated reference](/api/docs) defines required scopes and refusals.

## Rate limiting

Honor `Retry-After` when a request is rate limited. Avoid immediate retry
loops. A lost response to a mutation does not prove that the mutation failed;
reconcile the resource before you repeat an operation that could spend money.
See each operation's responses in the [generated reference](/api/docs).

## Agents

An agent is reusable configuration for a runtime and model. Create its
[environment](concepts/environment.md) and [vault](concepts/vault.md) first,
then reference them when you configure the agent.

Use version history to inspect configuration changes before a rollback.
See [Agents](concepts/agent.md) for the model and the Agents operations in
the [generated reference](/api/docs) for the complete contract.

## Catalog

Read the instance catalog before you offer runtime, provider, or app choices.
An integration should distinguish an unavailable capability from one that its
workflow does not require. The [generated reference](/api/docs) describes the
catalog response; the [Catalog](catalog/index.md) explains shipped resources.

## Environments

An environment supplies the packages, repositories, scripts, network policy,
and baseline secrets a machine needs. See [Environments](concepts/environment.md).
The [generated reference](/api/docs) defines the editable configuration and
secret operations. Changes can affect persistent machines built from it.

## Vaults

A vault supplies secret overrides without a duplicate environment.
See [Vaults](concepts/vault.md) for precedence and reuse. Submit secret values
through the write operations in the [generated reference](/api/docs); do not
expect read operations to return them.

## Secret bindings

Use broker bindings when a sandbox should reference a credential while the
broker supplies its value to an approved destination. The credential value stays outside the sandbox.

See [Secrets](concepts/secrets.md) for the security model and the binding
operations in the [generated reference](/api/docs) for configuration.

## Connections

A connection authorizes access to an external service through its OAuth flow.
It is distinct from an API key for Fountain. See
[Connections](catalog/connections/index.md) for supported services and setup.
The [generated reference](/api/docs) describes discovery and connection state.

### Connection providers

An instance must configure a provider before an account can connect it.
For an external service, follow [Register your own OAuth app](guides/connect/own-oauth-app.md).
Use provider discovery from the [generated reference](/api/docs) to decide
which connection choices the UI can offer.

## Bulk apply

Use `fountain apply` when a checked-in manifest should define several related
resources. The CLI compiles the manifest and submits the resource graph.
Inspect every resource result. One failed resource does not mean that all
other writes failed.

Each result row reports `created`, `updated`, `unchanged` or `error`. A
second apply of an unchanged manifest reports `unchanged` for every row, and
writes no audit event for those rows. Inline `spec.secrets` are encrypted
again on each apply, so they keep reporting `upserted` under a row that
reports `unchanged`.

See [CLI](cli.md) for the workflow and the Apply operation in the
[generated reference](/api/docs) for its wire format. Unknown configuration
keys fail validation before Fountain writes that resource's attributes or secrets.

## Conversations

Create a conversation with an agent and a first prompt, follow its events,
and send later prompts to that same conversation. Keep the returned ID.
A new conversation creates another thread.

Launch requests inherit the stricter host and account execution ceilings. Omitted, null or
empty `execution_limits` do not remove it. Wider requests return
`422 execution_limits_widen`; malformed requests or configured policy return
`422 execution_limits_invalid`. Nonempty effective limits return
`422 execution_limits_unsupported`; Fountain cannot yet enforce these controls.
These preflight checks cover fresh launches, sandbox attachments and channel
resumes before worker start or channel changes. This is not an atomic reservation
against later policy changes. Keep host and account ceilings empty until later-turn and
recovery checks and runtime enforcement are integrated. Fresh launches and
attachments save their initial allowance with the conversation before worker
startup or prompt delivery. Fresh launches also reserve the sandbox in that
transaction; a failed insert leaves no sandbox or conversation.

```bash
curl --fail-with-body \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"agent_id":"YOUR_AGENT_ID","prompt":"Describe the files in the workspace."}' \
  "$FOUNTAIN_URL/api/conversations"
```

This starts real work and can consume credits and provider usage.
[Conversation states](reference/conversation-states.md) explains lifecycle
transitions. The Conversations operations in the
[generated reference](/api/docs) define prompt admission, permission answers,
interruption, termination, history, images, and event streams.

Use history for a durable transcript and SSE for live delivery. Persist the
event cursor so a reconnect can resume after the last event processed.
Request structured blocks to render runtime output; clients should not
parse each runtime's native dialect.

### Workers without Fountain API access

Set `sandbox_api_access` to `none` when the host must retain Fountain API
authority. Fountain omits its sandbox callback credential before provision
and on every wake or reattachment. The default, `owner`, retains existing
behavior.

This setting is immutable. `none` requires a fresh ephemeral sandbox. It
cannot attach to an existing machine or share its machine with another
conversation. A channel resume with a different explicit setting fails.

Discover support in `GET /api/catalog` under `sandbox_api_access`. The host
can still send prompts and read events and files. The worker cannot use
Fountain MCP tools or connections that require its callback credential.

This option controls the credential Fountain creates. It does not remove
credentials supplied through environments, vaults, or custom MCP configuration.
Use a dedicated account containing only these workers for mutually untrusted
repositories. Keep the account's full API keys on the service host.

### Every conversation on one stream

Use the account event stream for a conversation list with live updates.
Refresh the list when a conversation-change notification arrives. Keep each
conversation's history available for reconciliation after a reconnect.

The Events operations in the [generated reference](/api/docs) define stream
selection, cursors, and framing. See [Build a chat app](build/index.md) for
how a client combines the list, transcript, and live stream.

## Sandboxes

A sandbox is the machine that hosts a conversation. Several conversations
can share it. Keep the distinction between a transcript and its machine
when you present reset or termination controls.

See [Sandboxes](concepts/sandboxes.md) and
[Sandbox lifetime](guides/operate/sandbox-lifetime.md). The Sandboxes operations
in the [generated reference](/api/docs) describe attachment identity, reset
conditions, and refusal during a turn.

### Files and git diff

Use the sandbox read operations to inspect files and tracked changes while
an agent works. Reads do not wake a parked machine. A diff does not include
untracked files, so it is not a complete inventory of the working directory.

The [generated reference](/api/docs) defines path confinement, byte limits,
truncation, encoding, and comparison options. Check truncation before you show
a response as a complete file. Treat redacted output as a display value.

## Search

Use account-scoped search to find resources and conversation content the caller
can access. Search results are navigation aids; fetch the selected resource
before you act on its current state. See Search in the
[generated reference](/api/docs).

## Team

A teammate is an agent with a stable conversation and optional communication
channels. Follow [Teammates](concepts/teammates.md) for the model and
[Build a team chat](build/team-chat.md) for the app workflow.

The Team operations in the [generated reference](/api/docs) describe roster,
messages, contact provisioning, and access. Check capability availability
before you offer email or phone features.

### Schedules

A schedule runs work without a person at the keyboard. Choose the intended
timezone and verify the next execution before you enable unattended work.
See [Teammates](concepts/teammates.md) for how schedules relate to a teammate.
The [generated reference](/api/docs) defines timing fields and run history.

## Support

Use the console's support action to report a problem or request access to a
feature. Include the conversation ID and the time of the failure. Review any
attached transcript for sensitive content before you submit it.

Support is an optional extension. Its operations appear in the
[generated reference](/api/docs) only when the instance installs it.

## Admin

Administrative workflows require an operator account and an appropriate key.
Use tenant-scoped resource reads for ordinary application work. An operator's
metadata access does not grant access to another tenant's prompt or output.

See Admin in the [generated reference](/api/docs) for account controls,
credit grants, sandbox maintenance, and privilege-trail events.

## Webhooks

Use webhooks when another server must react to Fountain events. Verify the
signature before you process an event. Make the delivery handler idempotent.
Follow [Webhooks](reference/webhooks.md) for delivery and retry behavior.
The [generated reference](/api/docs) describes endpoint registration and replay.

## Audit

Use the audit trail to investigate who changed a resource and when.
A transcript describes agent work; the audit trail describes account and
resource actions. The [generated reference](/api/docs) defines filters,
pagination, and returned metadata.

## Error responses

Handle errors with the operation's status and documented machine-readable
fields. Validation failures can include field errors; coded refusals need not.
Do not assume every error uses the same envelope. Content-negotiation errors
and compatibility endpoints can use different shapes.

The [generated reference](/api/docs) declares shared pipeline errors alongside
controller responses. Reconcile state after a timeout before you retry a
mutation. Honor retry guidance where present, and refresh credentials when
the response identifies an expired or revoked key.

## LLM-native discovery

Use `/llms.txt` for a short introduction, `/llms-full.txt` for the manual,
and `/skill` for an editor skill. Use the [OpenAPI document](/api/openapi.json)
for machine-readable endpoint contracts.
See [LLM integration](llm-integration.md) for integration guidance.
