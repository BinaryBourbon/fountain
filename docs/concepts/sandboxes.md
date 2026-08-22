# About sandboxes

This page explains what a sandbox is, why Fountain does not let you create
one, and what changes when you move to a different provider. For the
executable contract a backend must meet, read
[the sandbox contract](../integrations/sandbox-contract.md). To choose and
configure one, read [Self-host Fountain](../self-hosting.md).

## What a sandbox is

A sandbox is the isolated machine that one [conversation](conversation.md)
runs in.

It is not a primitive. You never create, name or address one. Fountain
provisions it when a conversation starts. Fountain reclaims it when the
conversation goes quiet, or when it runs too long.

That is deliberate. A sandbox you could create on its own would be a resource
you could leak. The machine that nobody remembered to stop is what makes agent
infrastructure expensive.

## Why the lifecycle belongs to the conversation

Tie the machine to the run, and three problems solve themselves.

Reclamation gets an owner. An idle conversation means an idle machine, and no
separate record can go wrong.

Cost gets a shape that a user recognises. "This conversation cost something"
reads clearly, and "you have 14 sandboxes" does not.

Memory gets somewhere to live. The runtime keeps its session on the sandbox's
disk. To suspend and wake the machine is therefore the same act as to pause
and resume the conversation. Read [About conversations](conversation.md).

## One seam, four backends

Each backend plugs into the same seam, `Fountain.Sandbox`. The contract is
executable, and not merely described. The behaviour specifies callbacks,
capabilities and an error taxonomy. A conformance suite that each adapter must
pass covers four things. It covers replay-from-start attach, total
`write_stdin`, exactly one terminal frame for each command, and `allow: []` as
deny-all.

| Provider | What it is | Suspend |
|---|---|---|
| [Sprites](../integrations/sprites.md) | The first backend, and the instance default. | Parks on its own, scales to zero, keeps the disk. |
| [E2B](../integrations/e2b.md) | Hosted. | An explicit pause, with a snapshot of filesystem **and memory**. |
| [Daytona](../integrations/daytona.md) | Hosted, and you can self-host it. | An explicit stop, keeps the disk, archives a long park. |
| [Self-hosted runner](../integrations/runners.md) | `fountain runner` on a machine the **user** owns. | Stops the processes. The directory stays. |

## Capabilities are honest, and that has consequences

An adapter advertises what it can truly do, from `:suspend`,
`:network_policy`, `:attach`, `:tty`, `:checkpoint` and `:public_url`. The
lifecycle then degrades to match, and it pretends nothing.

A provider without `:suspend` **destroys on idle**. It does not fake a park. A
resume with a fresh disk would lose the agent's memory without a sound, which
is worse than an honest teardown.

So the idle timeout does not mean the same thing everywhere. On Sprites it
costs nothing. On a provider with no suspend it costs the memory the agent
works from. Read
[Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).

Three more consequences matter.

**A runner gives you no isolation.** It runs in trusted mode on a machine the
user owns, with no egress policy. It is a way to use hardware you already
have. It is not a security boundary.

**Only Sprites gives you a TTY.**

**A sandbox never moves.** A parked disk stays where Fountain wrote it, so a
wake never crosses providers. Change the instance default and only new
sandboxes follow it.

## Anything an agent serves can be public

A provider that gives a sandbox its own HTTP endpoint advertises
`:public_url`. Fountain sets the URL in the sandbox as `SANDBOX_URL`, so an
agent can answer when you ask where it runs.

On Sprites that endpoint asks for a platform credential by default. Fountain
opens it, because an agent that serves a page serves it to a person, and that
person holds no such credential.

**So anyone with the URL can reach what an agent serves.** Set
`config :fountain, :sprites_public_urls, false` to keep the default instead.
A sandbox then keeps its URL, and only a token holder can open it.

## Not a container you can hand us

Fountain builds no image and stores no image. A provider applies your
[environment](environment.md) as a recipe at provision time. Two conversations
from the same environment install their packages one by one, on their own
machines.

That costs provision time. It buys you no registry, no build pipeline, and no
garbage-collection problem.

## Where to go next

- [The sandbox contract](../integrations/sandbox-contract.md), the executable
  version of this page.
- [About conversations](conversation.md), whose lifecycle this one follows.
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).
- [Add a provider](../integrations/adding-a-sandbox-provider.md), if you want
  a fifth.
