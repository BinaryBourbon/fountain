# Deploy an instance

This guide shows you how to get a Fountain instance running with Docker
Compose, register the first account, and close registration behind you.

For a development environment on your own machine, see [Setup](../../setup.md).
That is a different thing, and this guide assumes you want an instance that
stays up.

## Before you start

You need Postgres 16 or newer, which the compose file runs for you, and a
sandbox provider token. See [Self-hosting](../../self-hosting.md) for what each
provider needs.

## Bring it up

```bash
git clone https://github.com/BinaryBourbon/fountain
cd fountain

cp .env.compose.example .env
echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env
# add your SPRITES_TOKEN to .env

docker compose up -d
```

Back up `MASTER_SECRETS_KEY` now, before you have data. It is not in the
database, so a database backup alone does not protect you. See
[Back up and restore](back-up-and-restore.md).

The variables that shape a deployment are explained as they come up across
these guides. The complete list, including the deploy-level ones the compose
file never mentions, is the
[configuration reference](../../configuration.md).

## Register the first account

Open <http://localhost:4000> and register. That is the whole first login.

With the compose defaults (`EMAIL_DELIVERY=none`, `FIRST_USER_ADMIN=true`) your
account self-verifies at registration and, being the first, is promoted to
admin. The grant is recorded in the admin audit trail like any other role
change (ADR 0011).

Register **before** exposing the instance to a network you do not trust. While
no admin exists, the first verified account gets the role.

Prefer the manual path? Set `FIRST_USER_ADMIN=false` and use a release task
instead. See [Run a release task](run-a-release-task.md).

```bash
docker compose exec app bin/fountain_server eval \
  'Fountain.Release.promote_admin("you@example.com")'
```

## Point the apps at it

Fountain's own UI is a console, covering the account, its keys, and the agents,
environments and vaults a conversation runs on. Watching a conversation turn by
turn, and messaging an agent as a teammate, are separate single-page apps that
talk to your `/api`.

| | |
|---|---|
| [Conversations](https://jakegaylor.com/fountain-conversations/) | start a run, watch it, steer it, read the raw log |
| [Team](https://jakegaylor.com/fountain-team/) | your agents as teammates, one thread each |

They are static builds with no server of their own. You type your Fountain's
URL in, so the hosted copies above work against your deployment as soon as it
admits the origin.

```bash
echo "API_CORS_ORIGINS=https://jakegaylor.com" >> .env
```

If you would rather click "Sign in with Fountain" than paste an API key,
register them in `OAUTH_CLIENTS`. See the
[configuration reference](../../configuration.md).

The console links to whatever `CONVERSATIONS_APP_URL` and `TEAM_APP_URL` say,
so pointing those at your own build of either repo works the same way. Setting
them to `""` tells the console this deployment has neither, and it stops
offering them.

## Close registration

```bash
echo "REGISTRATION_ENABLED=false" >> .env
docker compose up -d
```

Registration is open by default, and an instance on the public internet with
registration open will be found.

## Verify it worked

```bash
curl -sS localhost:4000/health/ready
# {"checks":{"database":"ok"},"status":"ok"}
```

Then sign in and create a conversation. A run that reaches its first turn
proves the database, the secrets key and the sandbox provider are all wired.

## If it did not work

If provisioning fails but the app serves, the sandbox provider is the usual
cause. See [Sandbox errors](../../troubleshooting/sandbox-errors.md).

If the container never starts listening, migrations cannot reach the database.
See [Pods restarting or not ready](../../troubleshooting/pods-restarting.md).

## Related

- [Put it on the internet](put-it-on-the-internet.md), the next step.
- [Back up and restore](back-up-and-restore.md).
- [Configuration reference](../../configuration.md).
- [Architecture](../../architecture.md), for what runs and what breaks when a
  dependency is down.
