# Start before sign-in

A first-time visitor arrives at your app. You want a computer to start now, not
after a sign-up form. If the visitor makes an account later, that same computer
must be theirs, with the same disk and the same history.

A **claimable principal** is how Fountain does that. It is an anonymous tenant
that your application opens. It is a full tenant from its first request. It has
its own agents, environments, vaults, conversations and sandboxes. Nobody else
can read them.

The important property is the one you cannot get any other way. The principal
id never changes when somebody claims it. A sandbox name contains the tenant
id, so a transfer of resources between accounts is a different machine. A claim
touches no resource at all. It only records who is now behind the tenant.

[ADR 0044](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0044-claimable-principals.md)
is the decision, and the API reference is in [API](../api.md).

## What you need first

Your application needs its own Fountain account and a full-scope API key. That
account pays for every principal it opens, so put credit on it.

## Open a principal

```bash
curl -sX POST https://your-fountain/api/claimable-users \
  -H "Authorization: Bearer $FOUNTAIN_APPLICATION_KEY" \
  -H "Idempotency-Key: pdk_123" \
  -H "Content-Type: application/json" \
  -d '{
        "application_id": "paddock",
        "expires_in": 86400,
        "limits": { "max_live_sandboxes": 1, "max_cost_usd": 1 },
        "metadata": { "paddock_id": "pdk_123" }
      }'
```

```json
{
  "data": {
    "id": "0f1e…",
    "principal_id": "7b38…",
    "api_key": "ftn_…",
    "claim_token": "…",
    "status": "unclaimed",
    "expires_at": "2026-09-05T12:00:00Z"
  }
}
```

Keep `api_key` and `claim_token` in the visitor's session. Fountain stores only
their hashes and shows them once.

Now use `api_key` as any other Fountain key. Make an agent, start a
conversation, watch the events stream. The computer is live before the visitor
has an account.

!!! warning "Send an `Idempotency-Key`"

    A repeat of the same key returns the same principal, and a new pair of
    secrets. This is the only useful answer to a repeat, because Fountain
    kept neither secret from the first response. The pair from the first
    response stops working.

## What the anonymous key can do

The key has the `principal` scope. It reaches agents, environments, vaults,
conversations, sandboxes and the team. It reaches nothing that changes an
account.

| Refused | Why |
|---|---|
| `POST /api/auth/api-keys` | A principal must not mint a credential that outlives it. |
| `POST /api/claimable-users` | A principal must not open a second principal. |
| `/api/account/*`, `/api/connections` | An anonymous tenant has no account to configure. |
| `/api/claimable-users/:id` | A principal must not read or release its own grant. |

Each refusal is a `403` with `"reason": "insufficient_scope"`.

## Claim it

The visitor makes an account, or signs in to one they already have. Your app
then holds a normal full-scope key for that account. Send the claim token with
it.

```bash
curl -sX POST https://your-fountain/api/claimable-users/0f1e…/claim \
  -H "Authorization: Bearer $THEIR_KEY" \
  -H "Idempotency-Key: claim_1" \
  -H "Content-Type: application/json" \
  -d '{ "claim_token": "…" }'
```

```json
{
  "data": {
    "user": { "id": "9c22…", "email": "person@example.com" },
    "principal_id": "7b38…",
    "status": "claimed",
    "api_key": "ftn_…"
  }
}
```

`principal_id` is the same value as before. Every id under it is the same
value. Replace the anonymous key with the `api_key` in this response, because
the claim revoked the anonymous one.

An account that already owns other work claims the same way. The account
becomes the owner of a second tenant. It does not merge with it.

## What money does

Before a claim, work runs on the grant your application paid for. After a
claim, work runs on the balance of the account that claimed it. No ledger row
moves. Fountain reads the owner instead.

An exhausted grant is a `402` with `"error": "insufficient_credits"`. It is not
a sandbox error and not an agent error.

## Recover a lost response

Your app can lose the response to a create or a claim. Read the grant back.

```bash
curl -s https://your-fountain/api/claimable-users/0f1e… \
  -H "Authorization: Bearer $FOUNTAIN_APPLICATION_KEY"
```

`status` is one of `unclaimed`, `claimed`, `expired` or `released`. The
application that opened the grant reads it, and so does the account that
claimed it. Anybody else reads `404`, so nobody can probe an id.

A grant stays readable after it expires. Fountain deletes the principal itself
a week later.

## Give one back

```bash
curl -sX DELETE https://your-fountain/api/claimable-users/0f1e… \
  -H "Authorization: Bearer $FOUNTAIN_APPLICATION_KEY"
```

This revokes the credentials, destroys the sandboxes and refunds the unspent
part of the grant. A claimed principal belongs to the account that claimed it,
so this answers `409`.

## The states

```
   POST /api/claimable-users
        │
        ▼
   unclaimed ──── POST /:id/claim ────▶ claimed      the owner's tenant, forever
        │
        ├──────── expires_at passed ──▶ expired      credentials dead, grant refunded
        │
        └──────── DELETE /:id ────────▶ released     the same, on purpose
                                            │
                                            └── a week later, the principal is deleted
```
