# Self-hosting

Running your own Fountain instance.

For a development environment on your own machine, see [Setup](setup.md). That
is a different thing, and this section assumes you want an instance that stays
up.

Start with [Deploy an instance](guides/operate/deploy.md).

## What you need

| | |
|---|---|
| **Postgres 16+** | The compose file runs one for you |
| **A sandbox provider** | [sprites.dev](https://sprites.dev) by default. [E2B](integrations/e2b.md) and [Daytona](integrations/daytona.md) are hosted alternatives, and users can bring their own machines with [`fountain runner`](integrations/runners.md), which needs no credential. The app boots without one, but every conversation fails |
| **A mail provider** | Resend or any SMTP server. See [Configure email](guides/operate/email.md), which is a decision rather than an optional extra |

Sandboxes run on one of three backends, all hosted services. A Fountain
instance is not fully self-contained, and self-hosted Daytona comes closest.

| Provider | Enabled by | Idle behavior | Notes |
|---|---|---|---|
| **Sprites** (default) | `SPRITES_TOKEN` | Parks, scaling to zero on its own | The reference backend |
| **E2B** | `E2B_API_KEY` | Parks with an explicit pause, snapshotting filesystem and memory | Needs a template built from `images/e2b/`. See [E2B](integrations/e2b.md) |
| **Daytona** | `DAYTONA_API_KEY` | Parks with an explicit stop, preserving disk, archiving when long-parked | Self-hostable via `DAYTONA_API_URL`. See [Daytona](integrations/daytona.md) |

`SANDBOX_PROVIDER` picks the default for new sandboxes. An agent can pin a
provider, and existing sandboxes always stay where they were created.

For what each piece of the system does and what breaks when a dependency is
down, see [Architecture](architecture.md).

## The guides

**Standing it up.**

- [Deploy an instance](guides/operate/deploy.md)
- [Put it on the internet](guides/operate/put-it-on-the-internet.md)
- [Connect a database](guides/operate/database.md)
- [Deploy on Kubernetes](guides/operate/kubernetes.md)

**Decisions it forces.**

- [Configure email](guides/operate/email.md)
- [Change sandbox lifetimes](guides/operate/sandbox-lifetime.md)
- [Turn on billing](guides/operate/billing.md)

**Keeping it up.**

- [Back up and restore](guides/operate/back-up-and-restore.md)
- [Upgrade an instance](guides/operate/upgrade.md)
- [Wire up observability](guides/operate/observability.md)
- [Run a release task](guides/operate/run-a-release-task.md)

When something is wrong, start from
[Troubleshooting](troubleshooting/index.md).

## Licence

Fountain is MIT licensed. Running your own instance is explicitly fine,
including commercially.

## Known gaps

Being straight about what self-hosting does not yet include.

- **Sandbox backends are hosted dependencies.** Sprites, E2B and Daytona are
  all services, and self-hosted Daytona narrows this. The contract a new
  backend must satisfy is executable, `Fountain.Sandbox` plus its conformance
  suite, and written down in
  [the sandbox contract](integrations/sandbox-contract.md).
