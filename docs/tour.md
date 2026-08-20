# A guided tour: an agent that opens a pull request

By the end of this page you will have an agent that clones your repository,
makes a change, and opens a pull request — and you will be able to ask it for a
revision that lands on the same PR seconds later, because the computer it
worked on is still running.

It is about forty lines. Every number and every output below came from actually
running it.

## What you need

- A Fountain API key (Account → API keys, or `fountain auth login`).
- A repository you are willing to let an agent push a branch to.
- A GitHub token that can push to it. A
  [fine-grained token](https://github.com/settings/personal-access-tokens)
  scoped to that one repository is the right thing here — the agent gets a real
  credential, so give it the smallest one that works.

```bash
npm install fountain-sdk   # see the SDK page: not on npm yet, build from the repo
```

```ts
import { Fountain } from "fountain-sdk";

const fountain = new Fountain();          // FOUNTAIN_API_KEY
const REPO = "https://github.com/you/your-app";
```

## 1. The computer

An [environment](primitives.md) is the machine the agent gets, described once
and reused. Here it is a checkout of your repository:

```ts
const environment = await fountain.environments.create({
  name: "tour-workspace",
  repositories: [
    {
      url: REPO,
      mount_path: "/work/app",
      secret_key: "GITHUB_TOKEN",   // ← see the warning below
    },
  ],
  setup_script: "cd /work/app && npm install",
});
```

!!! warning "A private repository needs `secret_key`"

    `secret_key` names the secret the clone authenticates with. Leave it out on
    a **private** repository and the clone fails inside the sandbox — the
    conversation still starts, and your agent opens on an empty directory and
    tells you it cannot find the repo. Writing this page cost one wasted run to
    exactly that. A public repository does not need it.

## 2. The credential

A [vault](primitives.md) is a bag of secrets chosen per run. Its values are
decrypted into the sandbox when the sandbox spawns — they are never in the
prompt, never in the model's context, and never in the log feed:

```ts
const vault = await fountain.vaults.create({ name: "tour-github" });

await fountain.vaults.secrets.set("tour-github", "GITHUB_TOKEN", process.env.GITHUB_TOKEN!);
await fountain.vaults.secrets.set("tour-github", "GH_TOKEN", process.env.GITHUB_TOKEN!);
```

Two keys because two things need it: `GITHUB_TOKEN` is what the clone reads
(the `secret_key` above), and `gh` looks for `GH_TOKEN` when the agent opens
the PR.

You cannot read either one back — `secrets.list()` returns keys and nothing
else. And if the agent prints the token, Fountain redacts it out of the
transcript before it is stored.

## 3. The agent

The system prompt is where you say how the work should be done. Be specific
about the repository path and about what "done" means:

```ts
const agent = await fountain.agents.create({
  name: "tour-contributor",
  runtime: "claude",
  model: "anthropic/claude-sonnet-5",
  description: "Opens small pull requests",
  system:
    "You work in /work/app, a git repository. Make the smallest change that " +
    "satisfies the request, commit on a new branch, push, and open a pull " +
    "request with `gh`. Report the PR url and nothing else.",
  environment_id: environment.id,
  allowed_vault_ids: [vault.id],   // this agent may attach that vault, and no other
});
```

## 4. The run

```ts
const run = fountain.run(
  "Add a --version flag that prints 0.1.0 and exits. " +
    "Update the README. Then open a pull request.",
  { agent: "tour-contributor", vault: "tour-github" },
);

for await (const event of run) {
  if (event.type === "tool") console.log("·", event.name);
}

const result = await run;
console.log(result.text);
```

```text
· Terminal
· Read File
· Read File
· Edit
· Edit
· Terminal
· Terminal
· Terminal
· Terminal
· Terminal
https://github.com/you/your-app/pull/1
```

Forty-three seconds, most of it provisioning. The pull request is real: a
`--version` branch, two files changed, ten lines added.

If you would rather not watch, drop the loop — `await fountain.run(...)` gives
you the same result. If you would rather not wait at all, don't await it: hand
`run.conversationId` to whatever polls later.

## 5. The follow-up, which is the point

Ask for a revision:

```ts
const revision = await fountain
  .resume(result.conversationId)
  .send("Also accept -v as an alias for --version, and push it to the same PR.");
```

```text
turn 2 | done | +13s
https://github.com/you/your-app/pull/1
```

**Thirteen seconds, and the same PR.** Nothing was re-cloned, nothing was
re-explained, no second branch appeared. The sandbox is still up, the checkout
is on the branch the first turn made, `gh` is still authenticated, and the
agent's session still holds what it did and why. That is the difference between
an agent that has a computer and an agent that has a context window.

## 6. Clean up

```ts
await fountain.resume(result.conversationId).terminate();   // the sandbox
await fountain.agents.delete("tour-contributor");
await fountain.vaults.delete("tour-github");                // the credential first, in real code
await fountain.environments.delete("tour-workspace");
```

In a script that can fail, delete the vault in a `finally` — a credential
should not outlive the run that needed it.

## What you just built

| Piece | What it decided |
|---|---|
| Environment | which repository, cloned where, and what to run before the agent starts |
| Vault | which credential the sandbox gets, without it entering the prompt |
| Agent | the runtime, the model, and the standing instructions |
| Conversation | this run, and everything you can still ask it |

Swapping any one of them changes the job without touching the others: a
read-only token turns the same agent into one that can only report, and a
second environment points it at a different repository.

## The whole thing, in one script

Everything above, in one file you can copy and run. It is not a transcription
of the steps — it is `sdk/typescript/examples/pull-request.ts`, included here
verbatim, which is the same file that produced every output on this page.

```ts title="pull-request.ts"
--8<-- "sdk/typescript/examples/pull-request.ts"
```

```bash
FOUNTAIN_API_KEY=…  GITHUB_TOKEN=…  REPO_URL=https://github.com/you/your-app \
  node pull-request.ts
```

## Making it yours

- **Run it from CI.** The same forty lines work in an action; the agent needs
  no checkout on the runner, because the checkout is in the sandbox.
- **Make it a teammate.** `fountain.team.add("tour-contributor")` gives it a
  durable thread and a cron routine — "every Monday, open a PR bumping the
  dependencies" is `team.schedules.create`. See the [SDK page](sdk.md#the-team).
- **Fan it out.** `fountain.run()` per repository, awaited together; each gets
  its own sandbox.
- **Narrow the allowlist.** `allowed_vault_ids` is what stops this agent
  attaching a vault someone else set up.
