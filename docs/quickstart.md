# Run your first agent

This is the shortest path that demonstrates Fountain's whole job. An agent
starts in a sandbox with a real repository, inspects the checkout, and streams
its answer to your terminal.

The example uses Fountain's public repository. It needs no GitHub token, setup
script, package install, or Vault.

## Choose where Fountain runs

Run the server yourself, or use the hosted server. The manifest and the agent
run are the same on both.

### Run your own server

You need Docker, OpenSSL, and a sandbox provider token. The Compose file runs
Postgres. The example below uses Sprites as the sandbox provider.

```sh
git clone https://github.com/BinaryBourbon/fountain
cd fountain
cp .env.compose.example .env

echo "SECRET_KEY_BASE=$(openssl rand -base64 48 | tr -d '\n')" >> .env
echo "MASTER_SECRETS_KEY=$(openssl rand 32 | base64 | tr '+/' '-_' | tr -d '=\n')" >> .env

# Add your SPRITES_TOKEN to .env, then start Fountain.
docker compose up -d
```

Open <http://localhost:4000>. Create the first operator account, then add an
Anthropic credential under Settings, then Inference credentials.

The Compose defaults self-verify the first account and make it the admin.
Create that account before you expose the server to another network. The
[deployment guide](guides/operate/deploy.md) covers readiness, closing
registration, and the other sandbox providers.

### Use the hosted server

Create an account on [managoat.com](https://managoat.com), then add an
Anthropic credential under Settings, then Inference credentials. The hosted
server supplies the control plane and sandbox provider.

## Install and authenticate the CLI

```sh
brew install BinaryBourbon/tap/fountain
```

Point the CLI at the server you chose.

```sh
# Your own server
FOUNTAIN_BASE_URL=http://localhost:4000 fountain auth login

# Hosted server
fountain auth login
```

`auth login` saves the server URL and an API key. The commands below need no
server flag after that.

## Apply and run

Download the small manifest, apply it, and call the agent by name.

```sh
curl -fsSLo fountain.yml \
  https://raw.githubusercontent.com/BinaryBourbon/fountain/main/examples/quickstart/fountain.yml

fountain apply -f fountain.yml
fountain run fountain-reader -p \
  "Find the code that reclaims an idle sandbox. Explain when it runs and name the files you read."
```

`apply` creates two reusable rows. The Environment says which repository the
sandbox receives. The Agent says which runtime and model work in it.

`run` creates the Conversation. Fountain starts the sandbox, clones the
repository, starts Claude, and streams the work and final answer. The command
prints the conversation id first. Use it for a follow-up.

```sh
fountain conv prompt <conversation-id> -p \
  "Now trace the call one level deeper. What stops two reclaimers from racing?"
```

The follow-up lands on the same sandbox. The checkout and the agent session
are still there.

## What the example leaves out

The example has no Vault because it reads a public repository. Add a Vault
when a run needs a credential that changes independently from the machine or
the Agent. The [guided tour](tour.md) adds a GitHub token, changes a repository,
and opens a pull request.

The example uses Claude because it is Fountain's most exercised runtime. To
use Codex, Gemini CLI, or OpenCode, change `runtime` and `model` in the
manifest and add that provider's inference credential. The
[runtime catalog](catalog/runtimes/index.md) lists the accepted shapes.
