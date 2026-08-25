# Self-host Fountain

This section is about an instance of your own that stays up.

For a development environment on your own machine, read [Setup](setup.md).
That is a different thing.

Start with [Deploy an instance](guides/operate/deploy.md).

## What you must have

| | |
|---|---|
| **Postgres 16+** | The compose file runs one for you. |
| **A sandbox provider** | [sprites.dev](https://sprites.dev) is the default. [E2B](integrations/e2b.md) and [Daytona](integrations/daytona.md) are two more hosts. A user can also bring their own machine with [`fountain runner`](integrations/runners.md), which needs no credential. The app boots without a provider, but then each conversation fails. |
| **A mail provider** | Resend, or any SMTP server. Read [Configure email](guides/operate/email.md). It is a decision, and not an optional extra. |

A sandbox runs on one of three hosted backends, or on a user's own runner.
Somebody else runs all three hosted backends as a service, so a Fountain
instance is not self-contained. Self-hosted Daytona comes closest.

| Provider | Turned on by | When idle | Notes |
|---|---|---|---|
| **Sprites** (default) | `SPRITES_TOKEN` | Parks, and scales to zero on its own. | The reference backend. |
| **E2B** | `E2B_API_KEY` | Parks on an explicit pause, with a snapshot of filesystem and memory. | Needs a template built from `images/e2b/`. Read [E2B](integrations/e2b.md). |
| **Daytona** | `DAYTONA_API_KEY` | Parks on an explicit stop, keeps the disk, and archives a long park. | You can self-host it through `DAYTONA_API_URL`. Read [Daytona](integrations/daytona.md). |

`SANDBOX_PROVIDER` chooses the default for a new sandbox. An agent can pin a
provider. A sandbox that already exists always stays where Fountain made it.

[Architecture](architecture.md) says what each piece of the system does, and
what breaks when a dependency is down.

## The guides

**How to stand it up.**

- [Deploy an instance](guides/operate/deploy.md)
- [Put it on the internet](guides/operate/put-it-on-the-internet.md)
- [Connect a database](guides/operate/database.md)
- [Deploy on Kubernetes](guides/operate/kubernetes.md)

**The decisions it forces.**

- [Configure email](guides/operate/email.md)
- [Change sandbox lifetimes](guides/operate/sandbox-lifetime.md)
- [Start billing](guides/operate/billing.md) <!-- vale disable-line STE.IngForms -->

**How to keep it up.**

- [Back up and restore](guides/operate/back-up-and-restore.md)
- [Upgrade an instance](guides/operate/upgrade.md)
- [Wire up observability](guides/operate/observability.md)
- [Run a release task](guides/operate/run-a-release-task.md)

When something is wrong, start from
[Troubleshoot a problem](troubleshooting/index.md).

## Licence

The Fountain server uses the GNU AGPL v3.0 or later. You can run your own
instance. You can run it commercially.

The AGPL adds one obligation. Assume that you change the server, and that you
offer the changed server to other people over a network. You must then offer
those people the source of your changed version. A private instance for your
own company does not trigger this obligation. You do not offer a service to
third parties in that case.

The `ee/` directory holds the Stripe integration. That directory uses the
Elastic Licence 2.0. You can run the code in your own instance at no cost, and
your changes stay private. You must not offer that code to third parties as a
hosted service.

The `cli/` directory and the TypeScript SDK use the Apache Licence 2.0. Your
application gets no licence obligation when it calls the Fountain API.

Releases up to v0.12.0 used the MIT licence, and those releases stay MIT. The
`NOTICE` file at the repository root records the change.

## Known gaps

Here is what a self-hosted instance does not yet cover.

- **A sandbox backend is a dependency somebody else runs.** Sprites, E2B and
  Daytona are all services. Self-hosted Daytona narrows the gap. The contract
  that a new backend must satisfy is executable code, `Fountain.Sandbox` and
  its conformance suite, and
  [the sandbox contract](integrations/sandbox-contract.md) writes it down.
