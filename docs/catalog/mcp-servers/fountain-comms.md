# fountain-comms

> Gives a teammate its own email address and phone number, without giving it
> the keys.

## At a glance

| | |
|---|---|
| Hosted by | Fountain |
| Declared by | Nobody. Injected automatically |
| Injected when | The teammate has a contact, and the `team_comms` flag is on |
| Endpoint | `POST /api/mcp/team-comms/:conversation_id` |
| Auth | The sandbox's own per-conversation callback token |
| Status | Behind a feature flag |

## Why it exists this way

A teammate that can email people needs a mail credential. Putting one in the
sandbox would mean any agent that prints its environment has leaked the ability
to send mail as you.

So the credential does not go there. **Fountain owns the AgentMail and
AgentPhone keys.** Giving a teammate a contact creates an inbox and a number
under those keys, and the teammate reaches them only through these tools. The
sandbox never sees a key.

This is the same shape as [fountain-buzz](fountain-buzz.md), and the reasoning
generalises. When an agent needs a capability that a credential would grant,
serving the capability beats shipping the credential.

## The tools

Email tools appear only if the contact has an address, and SMS tools only if it
has a number. `my_contact_info` is always there.

| Tool | What it does |
|---|---|
| `email_send` | Send from the teammate's own address |
| `email_reply` | Answer a message it received. Prefer this over `email_send` for replies |
| `email_list` | Messages on its address |
| `email_get` | One message in full |
| `sms_send` | Send a text from its own number |
| `sms_list` | Texts on its number, newest first, sent and received |
| `my_contact_info` | Its own address and number, to share with people |

## A contact granted mid-session works on the next turn

Injection is recomputed at every turn kick rather than at provision. Give a
working teammate a contact and it can send mail on its next reply, with no
restart and no new sandbox.

## Limits

**Behind a flag.** `team_comms` gates the whole thing. With the flag off the
tools are absent, not merely inert.

**Teammates only.** A conversation that is not a teammate's gets nothing.

**One identity per teammate.** The address and number belong to the teammate,
so a fresh conversation under the same binding keeps them.

**Fountain sees the traffic.** The mail and messages pass through Fountain's
provider accounts, which is the cost of the sandbox not holding keys. If that
is the wrong trade for your data, do not grant a contact.

## Related

- [Agents as teammates](../../concepts/teammates.md).
- [fountain-buzz](fountain-buzz.md), the same pattern for Nostr.
- [MCP servers](index.md).
