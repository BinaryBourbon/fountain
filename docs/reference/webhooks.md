# Webhooks

Fountain POSTs conversation lifecycle events to a URL you own. This page is
the event catalogue, the payload envelope, how to verify the signature, and
what the delivery contract does and does not promise.

Webhooks are for finding out that something happened. They are not a
transcript. Read the [conversation events section](../api.md#conversations)
of the API reference when you need the output itself.

## When to use a webhook, and when to stream

`GET /api/conversations/:id/events` is a good stream and a bad integration
point. It needs a process that stays connected for the whole of a turn, which
can be twenty minutes, and it only ever tells you about one conversation.

| You have | Use |
|---|---|
| A GitHub Action, a Lambda, a cron script, a Slack app. | A webhook. |
| A chat UI rendering output as it arrives. | The SSE stream. |
| A dashboard that wants every conversation on the account. | A webhook. |
| A run that has to be watched from start to finish, live. | The SSE stream. |

Both can run at once. The webhook `id` field is the same id the stream sends,
so a client doing both can deduplicate against what it already rendered.

## Create an endpoint

```bash
fountain webhooks create https://example.com/hooks/fountain \
  --event conversation.turn.done \
  --event conversation.turn.failed
```

The signing secret is printed once and is never recoverable. It can be
replaced with `fountain webhooks rotate-secret <id>`, which invalidates the
old one immediately.

Over the API:

```bash
curl -X POST https://your-instance/api/webhooks \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://example.com/hooks/fountain",
       "event_types":["conversation.turn.done"]}'
```

With no `event_types` an endpoint is subscribed to
`conversation.turn.done`, `conversation.turn.failed` and
`conversation.provision.failed`, which is what most integrations want.

## The event catalogue

Every event type is `conversation.<stage>.<status>`. The stage and the status
are the same pair the SSE stream carries on a `stage` event, and the same
pair the Prometheus stage counter is tagged with.

| Stage | Statuses | What it means |
|---|---|---|
| `provision` | `started` `done` `failed` | The sandbox is being built. `failed` here means no agent ever ran. |
| `clone` | `started` `done` `failed` | Repositories declared on the environment are being cloned. |
| `packages` | `started` `done` `failed` | The environment's package commands are running. |
| `network` | `started` `done` `failed` | Egress policy is being applied to the sandbox. |
| `setup` | `started` `done` `failed` | The environment's setup script is running. |
| `checkpoint_restore` | `started` `done` `failed` | A checkpoint is being restored into the sandbox. |
| `reattach` | `started` `done` `failed` `interrupted` | The server is reconnecting to a sandbox after a restart. |
| `turn` | `started` `done` `failed` `interrupted` | One prompt and its reply. |
| `request` | `started` `done` | The agent asked permission to use a tool, and got an answer or timed out. |
| `model` | `failed` | The runtime refused the model the agent asks for. |
| `session` | `done` | The runtime reported a session id for the conversation. |
| `sandbox` | `done` | The sandbox was reclaimed. The conversation stays resumable. |
| `terminate` | `done` | The conversation ended. |

An endpoint's filter accepts three shapes.

- An exact type, `conversation.turn.done`.
- One stage, `conversation.turn.*`.
- Everything, `*`.

A typo in an exact type is rejected when you save the endpoint, rather than
silently subscribing you to nothing.

### Output does not come this way

`stdout` and `stderr` never produce webhooks. One chatty turn writes thousands
of output chunks, and turning those into HTTP POSTs is a denial of service on
both ends. Streaming output is what the SSE endpoint is for.

## The payload

```json
{
  "id": "918273",
  "type": "conversation.turn.done",
  "created_at": "2026-08-22T18:30:00.123456Z",
  "data": {
    "conversation_id": "0f2c…",
    "agent_id": "7ab1…",
    "parent_conversation_id": null,
    "status": "idle",
    "stage": "turn",
    "state": "done",
    "turn_id": "3d90…",
    "duration_ms": 42310
  }
}
```

| Field | Meaning |
|---|---|
| `id` | The log event row id, which is also the SSE event id. Stable and monotonic. |
| `type` | `conversation.<stage>.<status>`. |
| `created_at` | When the transition was recorded, in UTC with microseconds. |
| `data.status` | The conversation's status read at dispatch time. Advisory, and can be stale by a hair. `stage` and `state` are the authoritative pair. |
| `data.turn_id` | Present on turn events, null elsewhere. |
| `data.duration_ms` | How long the stage took, where the stage records one. |

**The payload carries no values.** No transcript text, no prompt, no
environment variable names, no secret values. This is the same rule the
audit trail runs on ([ADR 0013](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0013-audit-trail.md))
and it is there for the same reason. A payload is tenant data leaving the building over a URL
somebody typed into a form, and the delivery log would otherwise become a
second, less guarded copy of every conversation.

A receiver that wants the transcript calls
`GET /api/conversations/:id/events` with its own API key.

## Verify the signature

Every request carries four headers.

```
Fountain-Signature: t=1755203400,v1=8a1f…
Fountain-Event-Id: 918273
Fountain-Event-Type: conversation.turn.done
Fountain-Delivery-Attempt: 1
```

`v1` is `hmac_sha256(secret, "<t>.<raw request body>")`, hex encoded. The
timestamp is inside the signed string, so an attacker cannot move a captured
body forward in time and a receiver can enforce a replay window.

Verify against the **raw** body, before any JSON parsing. Re-encoding the
parsed object changes the bytes and the signature will not match.

```python
import hashlib, hmac, time

def verify(header, raw_body, secret, tolerance=300):
    parts = dict(p.split("=", 1) for p in header.split(","))
    timestamp = int(parts["t"])
    if abs(time.time() - timestamp) > tolerance:
        return False
    expected = hmac.new(
        secret.encode(),
        f"{timestamp}.".encode() + raw_body,
        hashlib.sha256,
    ).hexdigest()
    return hmac.compare_digest(expected, parts["v1"])
```

```javascript
import crypto from "node:crypto";

export function verify(header, rawBody, secret, tolerance = 300) {
  const parts = Object.fromEntries(
    header.split(",").map((p) => p.split("=", 2)),
  );
  const timestamp = Number(parts.t);
  if (Math.abs(Date.now() / 1000 - timestamp) > tolerance) return false;
  const expected = crypto
    .createHmac("sha256", secret)
    .update(`${timestamp}.`)
    .update(rawBody)
    .digest("hex");
  return crypto.timingSafeEqual(
    Buffer.from(expected),
    Buffer.from(parts.v1),
  );
}
```

Look the pair up by name rather than by position. A `v2` scheme would be added
alongside `v1`, not in place of it.

Fountain's own receiving side has the same problem and solves it the same way.
`FountainWeb.CachingBodyReader` is what keeps the raw body available for the
Stripe and AgentPhone webhooks, and it is worth copying if you build a Phoenix
receiver.

## The delivery contract

**At least once, with no ordering guarantee.** Retries and parallel delivery
both mean the same event can arrive twice and out of order. Deduplicate on
`id`, and never assume `conversation.turn.started` lands before its matching
`conversation.turn.done`.

Anything outside `200`-`299` is a failure and is retried. So is a redirect.
Fountain does not follow redirects, because a `302` to a private address
defeats the checks in the next section.

| Behaviour | Value |
|---|---|
| Attempts per event | 8, with exponential backoff, over roughly a day. |
| Request timeout | 10 seconds. |
| Redirects | Never followed. A `3xx` is a failure. |
| Response body read | The first 4 KB, kept for the delivery log. |
| Concurrency | One job per endpoint per event. A slow receiver cannot stall a fast one. |

Answer `2xx` as soon as you have the event stored. Doing the work inside the
request is what turns a 10 second timeout into a retry storm.

### When an endpoint is switched off

After 5 events in a row exhaust their retries, Fountain sets the endpoint to
`disabled`, stops delivering, and emails the account owner. Any delivery a
receiver accepts clears the counter, so a flaky receiver never trips it.

Fix the receiver, then resume the endpoint and send a test event.

```bash
fountain webhooks resume <id>
fountain webhooks test <id>
fountain webhooks deliveries <id>
```

## The delivery log

Every attempt is recorded with its status code, duration and the first few KB
of the response.

```bash
fountain webhooks deliveries <id>
```

```
id        event                     try  result  took    detail
a41c…     conversation.turn.done    1    500     212ms   {"error":"boom"}
a41c…     conversation.turn.done    2    500     198ms   {"error":"boom"}
b90f…     conversation.turn.done    1    200     84ms
```

`fountain webhooks redeliver <endpoint-id> <delivery-id>` sends one of them
again, against the endpoint's current URL and current secret. The same view
and the same button are on `/account/webhooks` in the console.

Delivery rows are pruned after 30 days by the retention sweep. They are a
debugging aid, not an event store.

## What a URL may point at

The URL is yours to choose and the request comes from inside Fountain's
network, so it is checked in three places.

- **When you save it.** `https://` is required, unless the instance sets
  `WEBHOOK_ALLOW_HTTP`. Credentials in the URL are refused.
- **Before every request.** The host is resolved and every address it answers
  with has to be publicly routable. Loopback, link local (which is where cloud
  metadata services live), RFC1918, carrier grade NAT, and the documentation
  and reserved blocks are all refused. Checking only at save time would be
  decorative, because DNS can change between the two.
- **During the request.** Fountain connects to the address it just checked,
  carrying your hostname in the `Host` header and in TLS SNI, so nothing can
  be swapped underneath the check.

`WEBHOOK_ALLOW_HTTP` relaxes the scheme rule only. It does not let a URL point
at a private address.

## Related

- [API reference](../api.md)
- [Conversation states](conversation-states.md)
- [Configuration reference](../configuration.md)
