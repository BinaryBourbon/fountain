# fountain

> Lets an agent spawn and stream more Fountain conversations from inside its
> own sandbox.

## At a glance

| | |
|---|---|
| Bundled | Yes, in every sandbox |
| Declared by | Nobody. It is always prepended |
| Source | `apps/fountain/priv/sprite_skills/fountain/SKILL.md` |
| Reads | `FOUNTAIN_BASE_URL`, `FOUNTAIN_TOKEN`, `FOUNTAIN_CONVERSATION_ID` |

## What it gives the agent

Fountain's own API, from the inside. An agent that has it can fan work out
across other agents and collect the answers.

Two patterns are written out in the skill. Fan out N conversations in parallel
and gather their results, and drive a single sub-conversation over multiple
turns.

This is what makes "delegate to another agent" work when a user asks for it.

## The credential it uses

`FOUNTAIN_TOKEN` is a **per-conversation key scoped to this conversation's
owner**, not a long-lived admin token.

Fountain rotates it on every fresh provision and every reattach, for example
after a deploy or a BEAM restart, revoking the previous value. A request that
returns 401 with `"reason": "api_key_revoked"` means the agent cached a stale
copy and should re-read the variable from its environment.

## Provenance is automatic

`FOUNTAIN_CONVERSATION_ID` is always in the sandbox's environment. A
`POST /api/conversations` that includes
`X-Fountain-Parent-Conversation-Id: $FOUNTAIN_CONVERSATION_ID` records the
parent, so an operator can reconstruct the whole spawn chain.

## Limits

**Spawned agents have the same skill.** Nothing stops recursion, so the skill
tells the agent to cap depth itself with a `MAX_DEPTH` check. A runaway fan-out
is a real way to spend money.

**Every conversation is a real sandbox.** The skill is explicit that orphaned
conversations run until the idle timeout, and that the agent should terminate
promptly. See
[Change sandbox lifetimes](../../guides/operate/sandbox-lifetime.md).

**The bare `/conversations` path is not the API.** It redirects to the login
page for non-browser requests. The API is under `/api`.

## Related

- [API reference](../../api.md), the same surface from outside.
- [Skills](index.md).
- [About conversations](../../concepts/conversation.md).
