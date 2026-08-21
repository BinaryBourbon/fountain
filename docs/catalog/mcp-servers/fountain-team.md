# fountain-team

> Lets a teammate see who else is on the team and message them.

## At a glance

| | |
|---|---|
| Hosted by | Fountain |
| Declared by | Nobody. Injected automatically |
| Injected when | The conversation is a teammate's, on the `fountain:team` channel |
| Endpoint | `POST /api/mcp/team/:conversation_id` |
| Auth | The sandbox's own per-conversation callback token |

## Why it exists

A team where the members cannot reach each other is a list, not a team.

With these tools, "send this to the engineer" becomes `get_teammate("engineer")`
then `send_to_teammate(id, text)`, and the reply comes back through
`read_teammate`. A lead teammate can route work without a human relaying it.

## The tools

| Tool | What it does |
|---|---|
| `list_teammates` | Everyone on the team, with name, agent id, purpose and current presence. The place to start |
| `get_teammate` | Resolve one by name, role or description. "the engineer", "whoever handles support". Returns the best match, or the candidates when ambiguous |
| `send_to_teammate` | Send to a teammate's thread. They receive it like a typed message, prefixed with who it is from. Returns their conversation id |
| `wait_for_teammate` | Block until their turn finishes, then return prompt, reply and status |
| `read_teammate` | Their recent turns, newest last, with status. Use after `send_to_teammate` to collect the answer |

A message sent this way lands in the receiving teammate's thread exactly as one
typed on the team page would, and the receiver sees who sent it. There is no
back channel.

## Two things that catch agents out

**`send_to_teammate` can fail with `busy` or `starting`.** A teammate mid-turn,
or one whose sandbox is still provisioning, cannot take a message yet. Wait and
retry.

**`wait_for_teammate` blocks for at most 90 seconds**, default 60. If it
returns `timed_out: true`, call it again. The important part is what the tool
description tells the agent explicitly: *do not end your own turn to wait*.
Ending the turn is how a delegation gets silently dropped.

Pass `since_turn` to wait for one specific reply rather than the latest turn.

## Limits

**Team conversations only.** A conversation not bound to the team channel gets
no tools at all, not an empty roster.

**No credential reaches the sandbox.** The tools run on Fountain's side, and
every call is tenant-scoped, so a teammate cannot reach another account's
roster whatever it sends.

**Presence is a point-in-time answer.** A teammate idle when you listed may be
busy when you send.

## Related

- [Agents as teammates](../../concepts/teammates.md), what this operates on.
- [MCP servers](index.md).
- [create-team](../skills/create-team.md), which builds the roster these tools
  read.
