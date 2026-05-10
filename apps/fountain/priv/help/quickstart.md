# Quickstart

Five minutes to your first conversation. Assumes the server is running and you have an admin token.

## 1. Set your token

```bash
export AOD_TOKEN=...           # the admin token from your .env
export AOD_BASE_URL=http://localhost:4000
```

## 2. Create an environment

The simplest possible — no packages, no clones, default networking.

```bash
curl -s -X POST "$AOD_BASE_URL/api/environments" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"name":"plain"}'
```

## 3. Create an agent

```bash
curl -s -X POST "$AOD_BASE_URL/api/agents" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"hello",
    "runtime":"claude",
    "model":"anthropic/claude-sonnet-4-6"
  }'
```

The runtime decides which CLI gets executed inside the sprite. See **Runtimes** for the four options and what each expects in `model`.

## 4. Start a conversation

```bash
AGENT_ID=$(curl -s "$AOD_BASE_URL/api/agents" -H "Authorization: Bearer $AOD_TOKEN" \
  | jq -r '.data[] | select(.name=="hello") | .id')

curl -s -X POST "$AOD_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $AOD_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"$AGENT_ID\",\"prompt\":\"Say hi.\"}"
```

This provisions a fresh sprite, mounts the bundled skills, runs your `setup_script` if any, then spawns the runtime CLI with the prompt. It returns immediately with the conversation id.

## 5. Wait for the answer

```bash
CONV=...

while :; do
  s=$(curl -s "$AOD_BASE_URL/api/conversations/$CONV" \
    -H "Authorization: Bearer $AOD_TOKEN" | jq -r .data.status)
  case "$s" in running|pending) sleep 2 ;; *) break ;; esac
done

curl -sN --max-time 5 \
  "$AOD_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
  -H "Authorization: Bearer $AOD_TOKEN" \
| awk '/^data: /{sub(/^data: /,""); print}' \
| jq -r '.data | fromjson? | select(.type=="result") | .result' \
| tail -n1
```

`wait=false` is important — without it the SSE stream stays open for ~60s waiting for new events. With it, the replay drains and the connection closes immediately.

## What's next

- **Vaults** — pick a bag of credential overrides at conversation creation (e.g. run as a different GitHub user).
- **Manifest** — declare agents, environments, and vaults in YAML and `aod apply` them.
- **Spawning sub-agents** — agents inside sprites can call back to spawn more agents.
- **API reference** — full OpenAPI at [/api/docs](/api/docs).
