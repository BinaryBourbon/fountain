# Run your first agent

This is the shortest path that demonstrates Fountain's whole job. An agent
starts in a sandbox with a real repository, inspects the checkout, and streams
its answer to your terminal.

The example uses Fountain's public repository. It needs no GitHub token, setup
script, package install, or Vault.

## Before you run it

You need a Fountain account with an Anthropic credential under Settings, then
Inference credentials. You also need the `fountain` CLI.

```sh
brew install BinaryBourbon/tap/fountain
fountain auth login
```

The CLI defaults to the hosted instance. For an instance of your own, set
`FOUNTAIN_BASE_URL` before `fountain auth login`.

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

## Run the server yourself

The hosted path above removes the control plane setup from the product demo.
Self-hosting has real inputs that a three-command example must not hide. A
Fountain server needs two encryption keys, Postgres, and a sandbox provider.
After the first boot, you create an account, add a model credential, and point
the CLI at the instance.

```sh
git clone https://github.com/BinaryBourbon/fountain
cd fountain
cp .env.compose.example .env
# Generate the two keys and add a sandbox provider token to .env.
docker compose up -d
```

[Deploy an instance](guides/operate/deploy.md) gives the commands and checks
for that path. Once `fountain auth login` targets the instance, the same
`apply` and `run` commands above work unchanged.
