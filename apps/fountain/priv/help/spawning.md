# Spawning sub-agents from inside a sprite

Every conversation gets two env vars in its sprite:

- `AOD_BASE_URL` — your Fountain server's public URL (e.g. `https://fountain.inevitable.fyi`)
- `AOD_TOKEN` — an API key the conversation can use to call back

Plus the bundled **`aod` skill** mounted under `~/.claude/skills/aod/` (or the runtime equivalent). With those three pieces, any agent inside a sprite can call back to the API and spawn more conversations.

> The env-var names (`AOD_*`) and the bundled skill name are leftovers from the project's previous name. They're stable contracts the bundled skill keys off of — renaming them would break every sprite-internal script. Treat them as opaque identifiers that mean "the Fountain callback URL/key".

## Patterns the agent will use

### Fan out

```bash
# Spawn N in parallel
ids=$(printf '%s\n' "First task" "Second task" "Third task" \
  | xargs -n1 -P8 -I{} sh -c '
    curl -s -X POST "$1/api/conversations" \
      -H "Authorization: Bearer $2" \
      -H "Content-Type: application/json" \
      -d "$(jq -n --arg a "$3" --arg p "$4" "{agent_id:\$a, prompt:\$p}")" \
    | jq -r .data.id
  ' _ "$AOD_BASE_URL" "$AOD_TOKEN" "$AGENT_ID" {})

# Wait for all in parallel
echo "$ids" | xargs -n1 -P10 -I{} sh -c '
  while :; do
    s=$(curl -s "$1/api/conversations/$3" -H "Authorization: Bearer $2" | jq -r .data.status)
    case "$s" in running|pending) sleep 2 ;; *) break ;; esac
  done
' _ "$AOD_BASE_URL" "$AOD_TOKEN" {}

# Gather final answers
while IFS= read -r conv; do
  curl -sN --max-time 5 \
    "$AOD_BASE_URL/api/conversations/$conv/stream?streams=stdout&wait=false" \
    -H "Authorization: Bearer $AOD_TOKEN" \
  | awk '/^data: /{sub(/^data: /,""); print}' \
  | jq -r '.data | fromjson? | select(.type=="result") | .result' \
  | tail -n1
done <<<"$ids"
```

### Block-and-return-result

Same shape but for one conversation at a time. The full bash function is in the bundled skill — `cat ~/.claude/skills/aod/SKILL.md` from inside any sprite.

## SSE wire format

```
id: 2694
event: output
data: {"data":"{\"type\":\"result\",...}","stream":"stdout","stage":"turn",...}

id: 2695
event: output
data: {"data":"{\"type\":\"assistant\",...}","stream":"stdout",...}
```

Two layers of JSON: outer is the SSE event envelope, inner is the runtime CLI's stream-json line. `awk` strips the `data:` prefix → jq parses the outer → `.data | fromjson` peels the inner. **Single fromjson, not double** — jq parses the awk output automatically.

## Per-runtime: where the final text lives

| runtime | jq selector for the terminal event | text path |
| --- | --- | --- |
| claude | `select(.type=="result")` | `.result` |
| codex | `select(.type=="item.completed" and .item.type=="agent_message")` | `.item.text` |
| gemini | `select(.type=="message" and .role=="assistant")` | `.content` (last one) |
| opencode | `select(.type=="text")` | `.part.text` (concatenate) |

## `wait=false` on the stream

The SSE endpoint normally holds open for ~60s waiting for new events. When the conversation is already done and you only want the replay, pass `wait=false` — it closes the moment the replay drains. Without it your `curl --max-time` sits idle for the full duration. **Always pass it for gather.**

## Security model — what to know

The sprite-side `AOD_TOKEN` is a regular Fountain API key — it carries the same blast radius the owning user has. Anything inside a sprite can create/delete agents, list conversations, etc. on behalf of that user. There's no per-conversation scoping today. Treat prompt-injection on a sprite-bound agent as a full account takeover for that user. Per-conversation scoped tokens are on the roadmap.

## Tunneling

For a sprite to call back, `AOD_BASE_URL` must be reachable from inside the sprite — `localhost` won't do. Local-dev cleanest option: [cloudflared](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/install-and-setup/tunnel-guide/local/) or [ngrok](https://ngrok.com). In production: whatever your hosted URL is.
