# Operator runbook

What to do when something's wrong with a running AoD instance. Single-tenant assumption throughout — if you're the operator, you're also the only user.

## Emergency switches

### Rotate the admin token

```bash
# Render dashboard → service env vars → ADMIN_TOKEN → set to new value → save
# Render redeploys automatically. While the deploy is in flight, both
# old and new instances are live; in-flight CLI/API sessions on the old
# token will 401 on next request.
```

The CLI picks up the new token on next run via `AOD_TOKEN`. UI sessions use a cookie keyed off the old token — you'll need to log in again.

### Rotate `SECRETS_KEY`

`SECRETS_KEY` is the AES-256 key encrypting `secrets.value_ciphertext` at rest. **Rotating it without re-encrypting** breaks every existing secret (decryption fails silently — `decrypted_env/1` skips them).

Re-encryption procedure (manual, no Mix task yet):

```elixir
# iex -S mix phx.server (or `bin/agent_on_demand remote`)
old_key = "<old SECRETS_KEY base64>" |> Base.url_decode64!(padding: false)
new_key = "<new SECRETS_KEY base64>" |> Base.url_decode64!(padding: false)

# Restore the old key, decrypt all secrets, hold them in memory
Application.put_env(:agent_on_demand, :secrets_key, old_key)

plain =
  AgentOnDemand.Repo.all(AgentOnDemand.Environments.Secret)
  |> Enum.map(fn s ->
    {:ok, v} = AgentOnDemand.Environments.Secret.decrypt(s)
    {s.id, v}
  end)

# Switch to the new key, re-encrypt + update
Application.put_env(:agent_on_demand, :secrets_key, new_key)

for {id, v} <- plain do
  s = AgentOnDemand.Repo.get!(AgentOnDemand.Environments.Secret, id)
  {:ok, _} = AgentOnDemand.Environments.upsert_secret(
    %AgentOnDemand.Environments.Environment{id: s.environment_id},
    %{"key" => s.key, "value" => v}
  )
end
```

Then update the `SECRETS_KEY` env var in your deploy and restart. Existing decrypted-in-memory secrets in running ConversationServers stay valid for the rest of those conversations.

## Stuck conversation

Symptoms: conversation status shows `running` but no SSE events arrive.

```bash
# 1. From the CLI:
./aod conv show <conv-id>          # see turn status, sandbox name
./aod conv interrupt <conv-id>     # stop the in-flight turn (sandbox lives)
./aod conv terminate <conv-id>     # destroy the sprite + mark conv terminated
```

If `interrupt` returns `no_turn_running`, the GenServer thinks no turn is in flight — most likely the sprite-side process exited and we missed the `:exit` message. Send a fresh prompt; `auto-wake` will spin up a new sandbox keeping the conversation history (claude `--resume` via persisted `runtime_session_id`).

## Orphaned sprites

Symptoms: sprites.dev billing shows sprites we don't recognize. AoD's `sandboxes` table doesn't have a row for them.

This shouldn't happen after a clean stop — `Rehydrator` reattaches on boot. It can happen after a hard kill (BEAM crash) on a sandbox that hadn't reached `ready` yet (those don't get rehydrated):

```bash
# List all sprites in your account
curl -sS https://api.sprites.dev/v1/sprites \
  -H "Authorization: Bearer $SPRITES_TOKEN" | jq -r '.[].name'

# Cross-reference with your AoD sandbox table
sqlite3 /data/agent_on_demand.db \
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
plug AgentOnDemandWeb.Plugs.RateLimit, bucket: "api", max: 1200
```

To clear the counter manually (e.g., in dev):

```elixir
# iex
:ets.delete_all_objects(AgentOnDemandWeb.Plugs.RateLimit.table())
```

## Audit log overgrows

The `audit_events` table is append-only. SQLite won't compact on its own.

```bash
# How big?
sqlite3 /data/agent_on_demand.db "SELECT count(*) FROM audit_events"

# Trim to last 30 days
sqlite3 /data/agent_on_demand.db \
  "DELETE FROM audit_events WHERE inserted_at < datetime('now', '-30 days')"

# Reclaim space
sqlite3 /data/agent_on_demand.db "VACUUM"
```

## SQLite backup + restore

```bash
# Backup (consistent — uses SQLite's backup API)
sqlite3 /data/agent_on_demand.db ".backup /data/agent_on_demand.bak"

# Restore (with the app stopped)
cp /data/agent_on_demand.bak /data/agent_on_demand.db
# Restart the service
```

For Render specifically: the disk at `/data` survives redeploys, so daily backups via a cron job is the simplest durability story.

## BEAM crash recovery

Symptoms: server is up but conversations show as `running`/`idle` from before the crash.

`Rehydrator` runs on every successful boot (see `application.ex` after `Supervisor.start_link`). It scans conversations whose status is non-terminal AND whose sandbox status was `ready` at the time of the stop, and starts a `ConversationServer` for each. The server enters reattach mode:

- If the sprite is still alive at sprites.dev → attach via `Sprites.list_sessions` + `attach_session`. Any in-flight detachable runtime command keeps streaming where it left off.
- If the sprite is gone → mark sandbox `failed`. The user's next prompt triggers `wake_conversation` to spin a fresh sandbox.

Conversations whose sandbox was `pending` or `starting` at the crash (mid-provision) are left as-is. The next user action resolves them via `wake_conversation`.

## Stuck OpenAPI validation

Symptoms: API call returns `422` with `{"errors":[{"message":"Missing field: <name>"}]}` for what looks like a valid payload.

Our request schemas are reused for POST and PUT today, so PUT requires the full Create shape. This is tracked under task #45. Workaround: include all the required fields on PUT, or use the LiveView UI which talks to the context functions directly (no OpenAPI gate).

## "I just deployed and the rate limiter keeps blocking me"

ETS table state survives redeploys-without-restart on Render's infrastructure but resets on cold start. If you're hitting limits immediately post-deploy, that's a real load issue, not a rollover artifact.

## Adding a new node (clustering)

Not yet supported. `Registry`, `DynamicSupervisor`, and `Phoenix.PubSub` are local. Tracking under task #37 (libcluster + Horde).
