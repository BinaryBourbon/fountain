# The four primitives

This page explains what Fountain's four objects are and why there are four of
them. For the fields on each one, see the [API reference](api.md). To build
something with them, start with the [guided tour](tour.md).

## The problem the four primitives divide up

To run a coding agent on a machine that is not yours, four things have to be
decided, and they change on four different schedules.

What the machine has on it changes rarely. Python 3.12, a checkout of your
repo, a setup script. You decide it once for a team and leave it alone for
months.

Which credentials the agent runs with changes constantly. A staging database
URL today, a customer's API key tomorrow, a rotated token an hour from now.

How the agent behaves changes occasionally. Which model, which runtime, which
skills, which MCP servers, what its system prompt says.

What it is doing right now changes every few seconds.

Put all four in one object and every credential rotation edits the machine
image, and every prompt edits the credentials. Fountain splits them into four
objects on purpose, and the split is the product.

| Primitive | Answers | Changes |
|---|---|---|
| [Environment](concepts/environment.md) | what is on the machine | rarely |
| [Vault](concepts/vault.md) | which credentials this run uses | constantly |
| [Agent](concepts/agent.md) | how the agent behaves | occasionally |
| [Conversation](concepts/conversation.md) | what it is doing right now | continuously |

## How they compose

An Agent names an Environment. A Conversation runs an Agent, and may name a
different Environment and attach a Vault for that run alone.

```
 Environment  ----->  Agent  ----->  Conversation
      ^                                   |
      +---- overridden per run -----------+
                                          |
 Vault  ------------ attached per run ----+
```

At the moment a Conversation starts, Fountain merges the Environment's secrets
with the Vault's secrets and hands the result to the sandbox as environment
variables. **The Vault wins on key collision.** That one rule is why the split
into four is usable rather than merely tidy, and it is set out in
[About vaults](concepts/vault.md).

## Substitution

All string values in Agent configs support `${VAR}` interpolation, resolved
from the merged environment and vault secrets at spawn time.

| Syntax | Result |
|---|---|
| `${VAR}` | The value of `VAR` from the merged map |
| `$$` | A literal `$` |

Substitution is recursive, so it works inside maps and lists. It is also
fail-complete. Every missing variable is reported at once rather than one per
attempt.

## What Fountain does not have

There is no fifth primitive, and two things that look like one are not.

A **team** is not an object. A teammate is a Conversation bound to the reserved
channel `fountain:team`. See
[Agents as teammates](concepts/teammates.md).

A **sandbox** is not an object you create. It is provisioned when a
Conversation starts and reclaimed when it ends. See
[About conversations](concepts/conversation.md).

## Where to go next

- **Learn by doing.** The [guided tour](tour.md) uses all four to open a pull
  request, in about forty lines.
- **Understand one primitive.**
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md),
  [Conversation](concepts/conversation.md).
- **Understand the machinery.** [Architecture](architecture.md) follows a
  prompt from the API call to the first token.
- **Look something up.** The [API reference](api.md) has every field,
  [Conversation states](reference/conversation-states.md) has the state table,
  and the [glossary](reference/glossary.md) has the overloaded words.
