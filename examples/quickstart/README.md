# Fountain quickstart

This is the smallest Fountain manifest that demonstrates a real sandbox. It
clones Fountain's public repository and gives a Claude agent the checkout. It
has no setup script, packages, Vault, or repository credential.

You need an authenticated `fountain` CLI and an Anthropic credential on your
Fountain account. Then run these two commands from the repository root.

```sh
fountain apply -f examples/quickstart/fountain.yml
fountain run fountain-reader -p \
  "Find the code that reclaims an idle sandbox. Explain when it runs and name the files you read."
```

The first command creates one Environment and one Agent. The second starts a
sandbox, clones the repository, runs the agent, and streams the answer back to
the terminal.

Read the [quickstart](../../docs/quickstart.md) for CLI installation, account
setup, and the self-hosted path.
