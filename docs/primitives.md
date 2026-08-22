# The four primitives

This page explains what Fountain's four objects are, and why there are four of
them. For the fields on each one, read the [API reference](api.md). To build
something with them, start with the [guided tour](tour.md).

## The problem the four primitives divide up

To run a coding agent on a machine that is not yours, you must decide four
things. Each of the four changes on its own schedule.

What the machine holds changes rarely. Python 3.12, a checkout of your repo, a
setup script. You decide it once for a team, then leave it alone for months.

Which credentials the agent runs with changes constantly. A staging database <!-- vale disable-line STE.IngForms -->
URL today, a customer's API key tomorrow, a rotated token an hour from now.

How the agent behaves changes sometimes. Which model, which runtime,
which skills, which MCP servers, and what its system prompt says.

What it does right now changes every few seconds.

Put all four in one object, and each credential rotation edits the machine
image. Each prompt edits the credentials. Fountain divides them into four
objects on purpose, and that division is the product.

| Primitive | Answers | Changes |
|---|---|---|
| [Environment](concepts/environment.md) | what the machine holds | rarely |
| [Vault](concepts/vault.md) | which credentials the run uses | constantly |
| [Agent](concepts/agent.md) | how the agent behaves | sometimes |
| [Conversation](concepts/conversation.md) | what it does now | continuously |

## How they compose

An Agent names an Environment. A Conversation runs an Agent. That Conversation
can name a different Environment, and it can attach a Vault for that one run.

```
 Environment  ----->  Agent  ----->  Conversation
      ^                                   |
      +---- overridden per run -----------+
                                          |
 Vault  ------------ attached per run ----+
```

A Conversation starts. At that moment Fountain merges the Environment's
secrets with the Vault's secrets, then hands the result to the sandbox as
environment variables. **The Vault wins on a key collision.** That one rule is
what makes the division into four usable and not merely tidy.
[About vaults](concepts/vault.md) sets it out.

## Substitution

Each string value in an Agent config takes a `${VAR}` reference. Fountain
resolves it from the merged environment and vault secrets at spawn time.

| Syntax | Result |
|---|---|
| `${VAR}` | The value of `VAR` from the merged map |
| `$$` | A literal `$` |

Substitution is recursive, so it works inside maps and lists. It is also
fail-complete. Fountain reports each absent variable at once, and not one for
each attempt.

## What Fountain does not have

There is no fifth primitive. Two things look like one and are not.

A **team** is not an object. A teammate is a Conversation bound to the reserved
channel `fountain:team`. Read
[Agents as teammates](concepts/teammates.md).

A **sandbox** is not an object you create. Fountain gives you one when a
Conversation starts, and takes it back when the Conversation ends. Read
[About conversations](concepts/conversation.md).

## Where to go next

- **Learn as you build.** The [guided tour](tour.md) uses all four to open a
  pull request, in about forty lines.
- **Understand one primitive.**
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md),
  [Conversation](concepts/conversation.md).
- **Understand the machinery.**
  [Where a secret comes from](concepts/secrets.md) follows a value from the
  master key to the process. [About sandboxes](concepts/sandboxes.md) covers
  the machine a run happens on. [Architecture](architecture.md) follows a
  prompt from the API call to the first token.
- **Look something up.** The [API reference](api.md) has each field.
  [Conversation states](reference/conversation-states.md) has the state table.
  The [glossary](reference/glossary.md) has the overloaded words.
