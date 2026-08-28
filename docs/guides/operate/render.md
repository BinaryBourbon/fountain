# Deploy on Render

This guide shows you how to bring up an instance on [Render](https://render.com)
from the blueprint in this repository. It then shows you what to set after the
first deploy.

For a machine you control, read [Deploy an instance](deploy.md). That guide
uses Docker Compose, and it is the shorter path.

## What the blueprint gives you

[`render.yaml`](https://github.com/BinaryBourbon/fountain/blob/main/render.yaml)
declares one web service and one managed Postgres. The web service runs the
published image, not a build of your checkout. The blueprint gives you an
instance that runs. It does not describe how the hosted service runs, which
is Kubernetes.

## Before you start

Fork this repository. Render reads the blueprint from a repository you own.

Generate the two keys now. You paste them during the next step.

```bash
openssl rand -base64 48 | tr -d '\n'                    # SECRET_KEY_BASE
openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n'   # MASTER_SECRETS_KEY
```

Back `MASTER_SECRETS_KEY` up before you have data. It is not in the database.
A database backup alone does not protect you. Read
[Back up and restore](back-up-and-restore.md).

You also need a sandbox provider token. Read
[Self-host Fountain](../../self-hosting.md) for what each provider needs.

## Apply it

In the Render dashboard, select **New**, then **Blueprint**, then your fork.
Render reads `render.yaml` and asks for three values.

| | |
|---|---|
| `SECRET_KEY_BASE` | The first key above. Render's own value generator makes a value that is too short for the cookie session store. |
| `MASTER_SECRETS_KEY` | The second key above. Render's generator cannot make this shape either. |
| `SPRITES_TOKEN` | Your sandbox provider token. |

Select **Apply**. The first deploy takes a few minutes, because the app
applies the database migrations before it opens a listener.

`PUBLIC_URL` is absent from the blueprint on purpose. A prod instance refuses
to boot without it, and the hostname does not exist before this first deploy.
Fountain reads Render's own `RENDER_EXTERNAL_URL` instead, so the first deploy
has a correct base URL.

## Register the first account

Open the service URL and register. The blueprint sets `EMAIL_DELIVERY=none`
and `FIRST_USER_ADMIN=true`, so your account self-verifies and becomes the
admin.

Register **before** you give the URL to anybody. While no admin exists, the
first verified account takes the role.

Then close registration in the Render dashboard, under **Environment**.

```
REGISTRATION_ENABLED=false
```

## Add a custom domain

Add the domain to the web service in the dashboard. Then set `PUBLIC_URL` to
the new address, with the scheme.

```
PUBLIC_URL=https://fountain.example.com
```

Set it. `RENDER_EXTERNAL_URL` still holds the `onrender.com` address, and
Fountain keeps that address in every verification email and in every sandbox
until you replace it.

## Run your own build

The blueprint runs the published image, which is the same image the compose
quick start runs. To run a fork with your own changes, replace the `runtime`
and `image` keys with these two lines.

```yaml
runtime: docker
dockerfilePath: ./Dockerfile
```

The build takes 15 to 25 minutes on Render's builders. It compiles the
umbrella, it builds the Go CLI, and it fetches the pinned Buzz binaries.

## What the blueprint does not do

- **It runs one instance.** Fountain clusters over Erlang distribution, and a
  Render service cannot discover its own peers. A second instance is not a
  second node, and two schedulers then race over the same sandboxes. Read
  [Architecture](../../architecture.md#clustering). Scale the plan instead of
  the instance count.
- **It sends no mail.** Accounts self-verify at registration in this mode
  (ADR 0011). Read [Configure email](email.md) for a real provider.
- **It trusts a wide proxy range.** Render terminates TLS at its edge, so the
  app sees the proxy and not the caller. The blueprint sets `TRUSTED_PROXIES`
  to the private ranges. Only Render's proxy reaches the container, so this is
  safe. Narrow it when you confirm the address that Render forwards from.
- **It does not back the database up.** Render takes its own snapshots on a
  paid plan. Read [Back up and restore](back-up-and-restore.md) for what a
  restore needs, and remember that a dump alone cannot decrypt itself.

## Upgrade

The blueprint pins a release tag, and `autoDeploy` is off. A push to your fork
does not move the pin.

Edit the tag in `render.yaml`, then apply the blueprint again.

```yaml
image:
  url: ghcr.io/binarybourbon/fountain:vX.Y.Z
```

Read [Upgrade an instance](upgrade.md) first. Migrations run at boot, and
Fountain does not support a downgrade.
