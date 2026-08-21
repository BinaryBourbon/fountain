# About sandboxes

This page explains what a sandbox is, why Fountain does not let you create one,
and what changes when you switch providers. For the executable contract a
backend must meet, see
[the sandbox contract](../integrations/sandbox-contract.md). To pick and
configure one, see [Self-hosting](../self-hosting.md).

## What a sandbox is

A sandbox is the isolated machine one [conversation](conversation.md) runs in.

It is not a primitive. You never create, name or address one. It is provisioned
when a conversation starts and reclaimed when the conversation goes quiet or
runs too long.

That is deliberate. A sandbox you could create independently would be a
resource you could leak, and the thing that makes agent infrastructure
expensive is machines nobody remembered to turn off.

## Why the lifecycle is attached to the conversation

Tie the machine to the run and three problems solve themselves.

Reclamation has an owner. When the conversation is idle, the machine is idle,
and there is no separate bookkeeping to get wrong.

Cost has a shape a user recognises. "This conversation cost something" is
legible in a way "you have 14 sandboxes" is not.

Memory has somewhere to live. The runtime keeps its session on the sandbox's
disk, so suspending and waking is the same thing as pausing and resuming the
conversation. See [About conversations](conversation.md).

## One seam, four backends

Every backend plugs into the same seam, `Fountain.Sandbox`. The contract is
executable rather than described. The behaviour specifies callbacks,
capabilities and an error taxonomy, and a conformance suite every adapter must
pass covers replay-from-start attach, total `write_stdin`, exactly one terminal
frame per command, and that `allow: []` means deny-all.

| Provider | What it is | Suspend |
|---|---|---|
| [Sprites](../integrations/sprites.md) | The original backend and the instance default | Parks implicitly, scaling to zero on its own, disk preserved |
| [E2B](../integrations/e2b.md) | Hosted | Explicit pause, snapshotting filesystem **and memory** |
| [Daytona](../integrations/daytona.md) | Hosted, self-hostable | Explicit stop, disk preserved, archiving when long-parked |
| [Self-hosted runner](../integrations/runners.md) | `fountain runner` on a machine the **user** owns | Stops processes, directory stays |

## Capabilities are honest, and that has consequences

An adapter advertises what it can actually do (`:suspend`, `:network_policy`,
`:attach`, `:tty`, `:checkpoint`, `:public_url`), and the lifecycle degrades
accordingly rather than pretending.

A provider without `:suspend` **destroys on idle** rather than faking a park.
Resuming with a fresh disk would be silent loss of the agent's memory, which is
worse than an honest teardown.

So the idle timeout does not mean the same thing everywhere. On Sprites it
costs nothing. On a provider without suspend it costs the agent's working
memory. See
[Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).

Three other consequences worth knowing.

**A runner has no isolation.** It runs in trusted mode on a machine the user
owns, with no egress policy. It is a way to use hardware you already have, not
a security boundary.

**TTY is Sprites-only.**

**Existing sandboxes never move.** A parked disk lives where it was written, so
waking never crosses providers, and switching the instance default only affects
new sandboxes.

## Anything an agent serves may be public

Providers that give a sandbox its own HTTP endpoint advertise `:public_url`,
and the URL is set inside the sandbox as `SANDBOX_URL` so an agent asked "where
is it running?" can answer.

On Sprites that endpoint defaults to requiring a platform credential, and
Fountain opens it, because an agent serving a page is doing it for a human who
has no such credential.

**So anything an agent serves is reachable by anyone with the URL.** Set
`config :fountain, :sprites_public_urls, false` to keep the default instead.
Sandboxes then keep their URLs and only a token holder can open them.

## Not a container you can hand us

Fountain does not build or store images. A provider applies your
[environment](environment.md) as a recipe at provision time, so two
conversations from the same environment install their packages independently.

That costs provisioning time and buys not having a registry, a build pipeline,
or a garbage-collection problem.

## Where to go next

- [The sandbox contract](../integrations/sandbox-contract.md), the executable
  version of this page.
- [About conversations](conversation.md), whose lifecycle this follows.
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md).
- [Adding a provider](../integrations/adding-a-sandbox-provider.md), if you
  want a fifth.
