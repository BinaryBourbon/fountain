# fountain-team

> Lets a teammate see who else is on the team, and message them.

## Summary

| | |
|---|---|
| Hosted by | Fountain |
| Declared by | Nobody. Fountain injects it. |
| Injected when | The conversation is a teammate's, on the `fountain:team` channel. |
| Endpoint | `POST /api/mcp/team/:conversation_id` |
| Auth | The sandbox's own callback token, for that one conversation. |

## Why it exists

A team whose members cannot reach each other is a list, and not a team.

With these tools, "send this to the engineer" becomes
`get_teammate("engineer")` and then `send_to_teammate(id, text)`. The reply
comes back through `read_teammate`. A lead teammate can route work, and no
person has to relay it.

## The tools

| Tool | What it does |
|---|---|
| `list_teammates` | Lists everyone on the team, with name, agent id, purpose and presence. Start here. |
| `get_teammate` | Resolves one by name, role or description. "the engineer", "whoever handles support". Returns the best match, or the candidates when the question is ambiguous. |
| `send_to_teammate` | Sends to a teammate's thread. They get it as a typed message, with the sender named in front. Returns their conversation id. |
| `wait_for_teammate` | Blocks until their turn finishes, then returns the prompt, the reply and the status. |
| `read_teammate` | Returns their recent turns, newest last, with status. Use it after `send_to_teammate` to collect the answer. |

A message sent this way lands in the thread of the teammate who gets it. It
lands exactly as a message typed on the team page does, and the reader sees
who sent it. There is no back channel.

The same roster is on the REST API, for a caller outside the sandbox.
`GET /api/team` lists it, and `POST /api/team/:agent_id/messages` sends a
turn. Read [Team](../../api.md#team). These tools are the view from inside
a teammate's own conversation, and they add no capability of their own.

## Two things that catch agents out

**`send_to_teammate` can fail with `busy` or `starting`.** A teammate in the
middle of a turn cannot take a message yet, and neither can one whose sandbox
is still on the way. Wait, then try again.

**`wait_for_teammate` blocks for 90 seconds at most**, and 60 by default. If
it returns `timed_out: true`, call it again. The tool description tells the
agent the important part: *do not end your own turn to wait*. An agent that
ends the turn is how a delegation gets dropped without a sound.

Pass `since_turn` to wait for one specific reply, and not for the latest turn.

## Limits

**Team conversations only.** A conversation off the team channel gets no tools
at all. It does not get an empty roster.

**No credential reaches the sandbox.** The tools run on Fountain's side, and
Fountain scopes each call to one tenant. A teammate cannot reach another
account's roster, whatever it sends.

**Presence is an answer for one point in time.** A teammate that was idle when
you listed can be busy when you send.

## Related

- [Agents as teammates](../../concepts/teammates.md), what this acts on.
- [Team](../../api.md#team), the same roster over the REST API.
- [MCP servers](index.md).
- [create-team](../skills/create-team.md), which builds the roster these tools
  read.
