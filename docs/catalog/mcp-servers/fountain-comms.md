# fountain-comms

> Gives a teammate its own email address and phone number, and gives it no
> keys.

## At a glance

| | |
|---|---|
| Hosted by | Fountain |
| Declared by | Nobody. Fountain injects it. |
| Injected when | The teammate has a contact, and the `team_comms` flag is on. |
| Endpoint | `POST /api/mcp/team-comms/:conversation_id` |
| Auth | The sandbox's own callback token, for that one conversation. |
| Status | Alpha. Behind the `team_comms` flag, off by default on the hosted platform. Read [Feature status](../../reference/feature-status.md). |

!!! note "Alpha"
    On the hosted platform the flag is off by default.
    [Ask us](../../api.md#support) to turn it on for your account. The tools
    and the routes can change between releases.

## Why it exists in this shape

A teammate that can email people needs a mail credential. Put one in the
sandbox, and any agent that prints its environment has leaked your ability to
send mail.

So the credential does not go there. **Fountain owns the AgentMail and
AgentPhone keys.** Give a teammate a contact, and Fountain creates an inbox
and a number under those keys. The teammate reaches them through these tools
alone, and the sandbox never sees a key.

This is the shape [fountain-buzz](fountain-buzz.md) has, and the argument
holds more widely. When an agent needs a capability that a credential would
grant, serve the capability. Do not ship the credential.

## The tools

The email tools appear only when the contact has an address. The SMS tools
appear only when it has a number. `my_contact_info` is always there.

| Tool | What it does |
|---|---|
| `email_send` | Sends from the teammate's own address. |
| `email_reply` | Answers a message it received. Use this for a reply, and not `email_send`. |
| `email_list` | Lists the messages on its address. |
| `email_get` | Returns one message in full. |
| `sms_send` | Sends a text from its own number. |
| `sms_list` | Lists the texts on its number, newest first, sent and received. |
| `my_contact_info` | Returns its own address and number, to share with people. |

## A contact granted mid-session works on the next turn

Fountain recomputes the injection at each turn kick, and not at provision.
Give a teammate a contact while it works, and it can send mail on its next
reply. It needs no restart and no new sandbox.

## Limits

**Behind a flag.** `team_comms` gates the whole thing. With the flag off, the
tools are absent, and not merely inert.

**Teammates only.** A conversation that is not a teammate's gets nothing.

**One identity for each teammate.** The address and the number belong to the
teammate. A fresh conversation on the same channel keeps them.

**Fountain sees the traffic.** The mail and the messages pass through
Fountain's provider accounts. That is the cost of a sandbox that holds no
keys. If that is the wrong trade for your data, grant no contact.

## Related

- [Agents as teammates](../../concepts/teammates.md).
- [fountain-buzz](fountain-buzz.md), the same pattern for Nostr.
- [MCP servers](index.md).
