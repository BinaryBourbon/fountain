# MCP servers

An MCP server gives a runtime tools it did not ship with. Fountain deals with
two kinds, and they work differently enough to be worth separating.

**Servers Fountain hosts.** Three of them, listed below. Nobody declares these
and no operator configures them. Fountain injects them into a conversation when
that conversation qualifies.

**Servers you declare.** Anything else, through the `mcp_servers` field on an
[Agent](../../concepts/agent.md). Fountain passes the declaration through and
does not curate a list.

## The three Fountain hosts

| Server | Injected when | Tools |
|---|---|---|
| [fountain-team](fountain-team.md) | the conversation is a teammate's | `list_teammates`, `get_teammate`, `send_to_teammate`, `wait_for_teammate`, `read_teammate` |
| [fountain-buzz](fountain-buzz.md) | the conversation's vault holds a Buzz identity | `buzz_send_message`, `buzz_react` |
| [fountain-comms](fountain-comms.md) | the teammate has a contact, behind flag `team_comms` | `email_send`, `email_reply`, `email_list`, `email_get`, `sms_send`, `sms_list`, `my_contact_info` |

Three properties are shared by all three, and each one is load-bearing.

**The sandbox never holds the credential.** This is the whole point.
`fountain-comms` is the clearest case: Fountain owns the AgentMail and
AgentPhone keys, and the teammate reaches email and SMS purely through tools.
No provider key enters the sandbox, so an agent that leaks its environment
leaks nothing that can send mail.

**They authenticate with the token the sandbox already has.** Each is served
over HTTP at a per-conversation URL, and the sandbox presents its
per-conversation callback token. There is no second credential to manage, and
the token is scoped to that conversation's owner.

**Injection is recomputed every turn.** A capability granted mid-session
appears on the next turn rather than at the next provision. Give a teammate a
contact while it is working and it can send mail on its next reply.

Every call is tenant-scoped, and a message sent through a tool lands in the
receiving teammate's thread exactly as one typed on the team page would, with
the sender attributed.

## Declaring your own

`mcp_servers` on an Agent takes a map of server definitions, with `${VAR}`
substitution in their `env` resolved from the merged environment and vault
secrets at spawn time.

```yaml
mcp_servers:
  github:
    command: npx
    args: ["-y", "@modelcontextprotocol/server-github"]
    env:
      GITHUB_PERSONAL_ACCESS_TOKEN: "${GITHUB_PAT}"
```

The credential comes from a [vault](../../concepts/vault.md) rather than being
written into the agent. See
[Where a secret comes from](../../concepts/secrets.md).

Note the difference from the hosted servers above. A server you declare runs
**inside** the sandbox and holds a real credential there. A server Fountain
hosts runs outside it and holds nothing.

### One runtime does this differently

On `claude`, session-scoped MCP delivery is broken upstream, so Fountain
provisions `.mcp.json` into the sandbox and enables project servers instead of
passing them per session. The effect is the same. The mechanism matters only if
you are debugging why a raw ACP probe behaves differently from Fountain. See
[claude](../runtimes/claude.md).

## No catalog of third-party servers

Fountain does not maintain a list of which MCP servers work, and this page is
not one.

Any server the runtime can launch will run. Whether it is a good idea is
between you and its author.

## Related

- [About agents](../../concepts/agent.md), where `mcp_servers` is declared.
- [Agents as teammates](../../concepts/teammates.md), which
  [fountain-team](fountain-team.md) serves.
- [Where a secret comes from](../../concepts/secrets.md).
