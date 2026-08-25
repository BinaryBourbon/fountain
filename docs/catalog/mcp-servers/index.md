# MCP servers

An MCP server gives a runtime tools that it did not ship with. Fountain deals
with two kinds. They work differently enough to keep apart.

**Servers Fountain hosts.** Three of them, listed below. Nobody declares these
and no operator configures them. Fountain injects them into a conversation
when that conversation qualifies.

**Servers you declare.** Everything else, through the `mcp_servers` field on
an [Agent](../../concepts/agent.md). Fountain passes the declaration through
and curates no list.

## The three Fountain hosts

| Server | Injected when | Tools |
|---|---|---|
| [fountain-team](fountain-team.md) | The conversation is a teammate's. | `list_teammates`, `get_teammate`, `send_to_teammate`, `wait_for_teammate`, `read_teammate` |
| [fountain-buzz](fountain-buzz.md) | The conversation's vault holds a Buzz identity. | `buzz_send_message`, `buzz_react` |
| [fountain-comms](fountain-comms.md) | The teammate has a contact, behind flag `team_comms`. | `email_send`, `email_reply`, `email_list`, `email_get`, `sms_send`, `sms_list`, `my_contact_info` |

All three share three properties, and each property carries weight.

**The sandbox never holds the credential.** That is the whole point.
`fountain-comms` is the clearest case. Fountain owns the AgentMail and
AgentPhone keys, and the teammate reaches email and SMS through tools alone.
No provider key enters the sandbox, so an agent that leaks its environment
leaks nothing that can send mail.

**They authenticate with the token the sandbox already holds.** Fountain
serves each one over HTTP at a URL for that one conversation, and the sandbox
presents its own callback token. There is no second credential to manage, and
the token reaches only that conversation's owner.

**Fountain recomputes the injection at each turn.** A capability granted
mid-session appears on the next turn, and not at the next provision. Give a
teammate a contact while it works, with `POST /api/team/:agent_id/contact`,
and it can send mail on its next reply. Read [Team](../../api.md#team).

Fountain scopes each call to one tenant. A message that goes through a tool
lands in the thread of the teammate who gets it. It lands exactly as a message
typed on the team page does, and it names the sender.

## How to declare your own

`mcp_servers` on an Agent takes a map of server definitions. Their `env` takes
`${VAR}` substitution, which Fountain resolves from the merged environment and
vault secrets at spawn time.

```yaml
mcp_servers:
  github:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

The credential comes from a [vault](../../concepts/vault.md). Nobody writes it
into the agent. Read
[Where a secret comes from](../../concepts/secrets.md).

Note how that differs from the hosted servers above. A server you declare runs
**in** the sandbox, and it holds a real credential there. A server Fountain
hosts runs outside the sandbox and holds nothing there.

### One runtime does this differently

On `claude`, an upstream defect breaks session-scoped MCP delivery. So
Fountain provisions `.mcp.json` into the sandbox and starts the project
servers, and it does not pass them for each session. The effect is the same.
The mechanism matters only when you debug why a raw ACP probe behaves one way
and Fountain behaves another. Read [claude](../runtimes/claude.md).

## No catalog of third-party servers

Fountain keeps no list of which MCP servers work, and this page is not one.

Any server the runtime can launch will run. Whether it is a good idea is
between you and its author.

## Related

- [About agents](../../concepts/agent.md), where you declare `mcp_servers`.
- [Agents as teammates](../../concepts/teammates.md), which
  [fountain-team](fountain-team.md) serves.
- [Where a secret comes from](../../concepts/secrets.md).
