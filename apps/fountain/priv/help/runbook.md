# Operator runbook

What to do when something's wrong with a running Fountain instance.

## Emergency switches

### Revoke or rotate a user's API keys

API keys are minted per-user and SHA-256-hashed at rest. Either revoke a single leaked key, or revoke them all and have the user re-issue.

```bash
# Single key
fountain keys list                  # find the id
fountain keys revoke <id>

# Or via the API as the affected user
curl -s -X DELETE "$FOUNTAIN_BASE_URL/api/auth/api-keys/<id>" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY"
```

CLI sessions pick up the change on next request (401 on the revoked key). UI sessions are cookie-backed and continue until logout/timeout.

### Rotate `MASTER_SECRETS_KEY`

`MASTER_SECRETS_KEY` wraps each tenant's data encryption key (DEK), stored in `user_data_keys.wrapped_key`. The DEKs themselves never change on rotation — only the wrap does. **Updating the env var without re-wrapping** breaks every login (`load_tenant_key/1` returns `{:error, :unwrap_failed}` on every conversation start).

Re-wrapping procedure (manual — bin/server remote on the running node):

```elixir
old_master = "<old MASTER_SECRETS_KEY base64>" |> Base.url_decode64!(padding: false)
new_master = "<new MASTER_SECRETS_KEY base64>" |> Base.url_decode64!(padding: false)

# Restore the old master, unwrap every tenant DEK in memory
Application.put_env(:fountain, :master_secrets_key, old_master)

deks =
  Fountain.Repo.all(Fountain.Accounts.UserDataKey)
  |> Enum.map(fn udk ->
    {:ok, dek} = Fountain.Crypto.load_tenant_key(udk.user_id)
    {udk.id, dek}
  end)

# Switch to the new master, re-wrap and persist
Application.put_env(:fountain, :master_secrets_key, new_master)

for {id, dek} <- deks do
  udk = Fountain.Repo.get!(Fountain.Accounts.UserDataKey, id)
  udk
  |> Ecto.Changeset.change(wrapped_key: Fountain.Crypto.wrap_dek(dek))
  |> Fountain.Repo.update!()
end
```

Then update the `MASTER_SECRETS_KEY` env var in your deploy and restart. DEKs already loaded into running ConversationServers stay valid for the rest of those conversations — they're held in GenServer state, not re-fetched per request.

## Stuck conversation

Symptoms: conversation status shows `running` but no SSE events arrive.

```bash
fountain conv show <conv-id>          # see turn status, sandbox name
fountain conv interrupt <conv-id>     # stop the in-flight turn (sandbox lives)
fountain conv terminate <conv-id>     # destroy the sprite + mark conv terminated
```

If `interrupt` returns `no_turn_running`, the GenServer thinks no turn is in flight — most likely the sprite-side process exited and we missed the `:exit` message. Send a fresh prompt; `wake_conversation` will spin up a new sandbox, keeping the conversation history (claude `--resume` via persisted `runtime_session_id`).

## Orphaned sprites

Symptoms: sprites.dev billing shows sprites we don't recognize. Fountain's `sandboxes` table doesn't have a row for them.

This shouldn't happen after a clean stop — `Fountain.Conversations.Rehydrator` reattaches on boot. It can happen after a hard kill (BEAM crash) on a sandbox that hadn't reached `ready` yet (those don't get rehydrated):

```bash
# List all sprites in your account
curl -sS https://api.sprites.dev/v1/sprites \
  -H "Authorization: Bearer $SPRITES_TOKEN" | jq -r '.[].name'

# Cross-reference with your Fountain sandbox table (run on Render via the
# Postgres dashboard, or psql against DATABASE_URL)
psql "$DATABASE_URL" -c \
  "SELECT sprite_name FROM sandboxes WHERE status NOT IN ('terminated','failed')"

# Anything in the first list not in the second is an orphan. Destroy:
curl -sS -X DELETE https://api.sprites.dev/v1/sprites/<name> \
  -H "Authorization: Bearer $SPRITES_TOKEN"
```

## Rate limit overflow

Symptoms: API returns `429 rate_limited` with a `Retry-After` header.

The default bucket is 600 req/min per IP. If a script is hot-looping, the response itself tells you when to retry. Don't drop the limit globally; instead bump it for that endpoint:

```elixir
# router.ex
plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 1200
```

To clear the counter manually (e.g., in dev):

```elixir
# bin/server remote
:ets.delete_all_objects(FountainWeb.Plugs.RateLimit.table())
```

## Audit log overgrows

The `audit_events` table is append-only.

```bash
# How big?
psql "$DATABASE_URL" -c "SELECT count(*) FROM audit_events"

# Trim to last 30 days
psql "$DATABASE_URL" -c \
  "DELETE FROM audit_events WHERE inserted_at < NOW() - INTERVAL '30 days'"

# Reclaim space (Postgres handles this with autovacuum normally; force if needed)
psql "$DATABASE_URL" -c "VACUUM ANALYZE audit_events"
```

## Postgres backup + restore

On Render, daily backups are managed by the Postgres add-on dashboard — there's nothing to wire up. Manual snapshots:

```bash
# Backup
pg_dump "$DATABASE_URL" > fountain.sql

# Restore (with the app stopped, against a fresh database)
psql "$NEW_DATABASE_URL" < fountain.sql
```

## BEAM crash recovery

Symptoms: server is up but conversations show as `running`/`idle` from before the crash.

`Fountain.Conversations.Rehydrator` runs on every successful boot (see `apps/fountain/lib/fountain/application.ex` after `Supervisor.start_link`). It scans conversations whose status is non-terminal AND whose sandbox status was `ready` at the time of the stop, and starts a `ConversationServer` for each. The server enters reattach mode:

- If the sprite is still alive at sprites.dev → attach via `Sprites.list_sessions` + `attach_session`. Any in-flight detachable runtime command keeps streaming where it left off.
- If the sprite is gone → mark sandbox `failed`. The user's next prompt triggers `wake_conversation` to spin a fresh sandbox.

Conversations whose sandbox was `pending` or `starting` at the crash (mid-provision) are left as-is. The next user action resolves them via `wake_conversation`.

## Stuck OpenAPI validation

Symptoms: API call returns `422` with `{"errors":[{"message":"Missing field: <name>"}]}` for what looks like a valid payload.

Our request schemas are reused for POST and PUT today, so PUT requires the full Create shape. Workaround: include all the required fields on PUT, or use the LiveView UI which talks to the context functions directly (no OpenAPI gate).

## "I just deployed and the rate limiter keeps blocking me"

ETS table state survives redeploys-without-restart on Render's infrastructure but resets on cold start. If you're hitting limits immediately post-deploy, that's a real load issue, not a rollover artifact.

## Adding a new node (clustering)

`libcluster` with the `Cluster.Strategy.DNSPoll` topology is wired up via `CLUSTER_DNS_QUERY` (see `config/runtime.exs`). On Render, set it to the internal DNS name of the service for multi-instance deployments. `Registry`, `DynamicSupervisor`, and `Phoenix.PubSub` are still local — cross-node ConversationServer routing isn't implemented yet.
