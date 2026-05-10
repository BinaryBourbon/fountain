# Quickstart

Five minutes to your first conversation. Assumes the server is running and you have a Fountain account.

## 1. Install the CLI and log in

Pre-built binaries are attached to each [GitHub release](https://github.com/BinaryBourbon/fountain/releases). One-shot install for macOS arm64:

```bash
curl -L -o fountain https://github.com/BinaryBourbon/fountain/releases/latest/download/fountain-darwin-arm64
chmod +x fountain && sudo mv fountain /usr/local/bin/
```

Then log in — this writes an API key to `~/.fountain/credentials`:

```bash
fountain auth login
```

For one-off scripting you can skip the credentials file and export the key directly:

```bash
export FOUNTAIN_API_KEY=...                        # an API key from `fountain keys create`
export FOUNTAIN_BASE_URL=http://localhost:4000     # only if not pointing at fountain.inevitable.fyi
```

## 2. Create an environment

The simplest possible — no packages, no clones, default networking.

```bash
curl -s -X POST "$FOUNTAIN_BASE_URL/api/environments" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"name":"plain"}'
```

## 3. Create an agent

```bash
curl -s -X POST "$FOUNTAIN_BASE_URL/api/agents" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "name":"hello",
    "runtime":"claude",
    "model":"anthropic/claude-sonnet-4-6"
  }'
```

The runtime decides which CLI gets executed inside the sprite. See **Runtimes** for the four options and what each expects in `model`.

## 4. Start a conversation

The CLI handles the create-and-stream flow in one shot:

```bash
fountain run hello -p "Say hi."
```

If you'd rather drive the API yourself:

```bash
AGENT_ID=$(curl -s "$FOUNTAIN_BASE_URL/api/agents" -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  | jq -r '.data[] | select(.name=="hello") | .id')

curl -s -X POST "$FOUNTAIN_BASE_URL/api/conversations" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
  -H "Content-Type: application/json" \
  -d "{\"agent_id\":\"$AGENT_ID\",\"prompt\":\"Say hi.\"}"
```

This provisions a fresh sprite, mounts the bundled skills, runs your `setup_script` if any, then spawns the runtime CLI with the prompt. It returns immediately with the conversation id.

## 5. Wait for the answer

```bash
CONV=...

while :; do
  s=$(curl -s "$FOUNTAIN_BASE_URL/api/conversations/$CONV" \
    -H "Authorization: Bearer $FOUNTAIN_API_KEY" | jq -r .data.status)
  case "$s" in running|pending) sleep 2 ;; *) break ;; esac
done

curl -sN --max-time 5 \
  "$FOUNTAIN_BASE_URL/api/conversations/$CONV/stream?streams=stdout&wait=false" \
  -H "Authorization: Bearer $FOUNTAIN_API_KEY" \
| awk '/^data: /{sub(/^data: /,""); print}' \
| jq -r '.data | fromjson? | select(.type=="result") | .result' \
| tail -n1
```

`wait=false` is important — without it the SSE stream stays open for ~60s waiting for new events. With it, the replay drains and the connection closes immediately.

## What's next

- **Vaults** — pick a bag of credential overrides at conversation creation (e.g. run as a different GitHub user).
- **Manifest** — declare agents, environments, and vaults in YAML and `fountain apply` them.
- **Spawning sub-agents** — agents inside sprites can call back to spawn more agents.
- **API reference** — full OpenAPI at [/api/docs](/api/docs).
