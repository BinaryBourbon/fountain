# The four primitives

This page explains what Fountain's four objects are, and why there are four of
them. For the fields on each one, read the [API reference](api.md). To build
something with them, start with the [guided tour](tour.md).

## The problem the four primitives divide up

To run a coding agent on a machine that is not yours, you must decide four
things. Each of the four changes on its own schedule.

What the machine holds changes rarely. Python 3.12, a checkout of your repo, a
setup script. You decide it once for a team, then leave it alone for months.

Which credentials the agent runs with changes constantly. A staging database <!-- vale disable-line STE.IngForms -->
URL today, a customer's API key tomorrow, a rotated token an hour from now.

How the agent behaves changes sometimes. Which model, which runtime,
which skills, which MCP servers, and what its system prompt says.

What it does right now changes every few seconds.

Put all four in one object, and each credential rotation edits the machine
image. Each prompt edits the credentials. Fountain divides them into four
objects on purpose, and that division is the product.

| Primitive | Answers | Changes |
|---|---|---|
| [Environment](concepts/environment.md) | what the machine holds | rarely |
| [Vault](concepts/vault.md) | which credentials the run uses | constantly |
| [Agent](concepts/agent.md) | how the agent behaves | sometimes |
| [Conversation](concepts/conversation.md) | what it does now | continuously |

## How they compose

An Agent names an Environment. A Conversation runs an Agent. That Conversation
can name a different Environment, and it can attach a Vault for that one run.

Three of the four are templates. They are rows that you write once and use
many times. The fourth, the Conversation, is a run on a machine. The machine
is the heavy work, and Fountain does it for you.

<figure>
<svg viewBox="0 0 740 352" role="img" aria-label="Three templates and one machine. Agent, Environment and Vault are rows a tenant writes once. When a conversation starts, Fountain builds a sandbox from the Environment, runs the Agent on it as a conversation, and merges the Environment's and the Vault's secrets, the Vault winning. On a hosted account with the egress broker on, a bound secret goes to the broker and the sandbox gets a placeholder; the sandbox reaches the internet only through the broker, which attaches the value. On any other account the secrets enter the sandbox as environment variables." style="max-width:100%;height:auto">
  <defs>
    <marker id="pr-a" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="currentColor"/></marker>
    <marker id="pr-b" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#c98a2b"/></marker>
  </defs>
  <g fill="none" stroke="currentColor" stroke-width="1.4">
    <rect x="14" y="30" width="196" height="52" rx="8" stroke="#8a93a3"/>
    <rect x="14" y="110" width="196" height="52" rx="8" stroke="#8a93a3"/>
    <rect x="14" y="190" width="196" height="52" rx="8" stroke="#8a93a3"/>
    <rect x="270" y="176" width="196" height="66" rx="8" stroke="#2f8fb3" stroke-width="1.8"/>
    <rect x="510" y="16" width="216" height="196" rx="8" stroke="#2f8fb3" stroke-width="1.8"/>
    <rect x="522" y="44" width="96" height="42" rx="6"/>
    <rect x="626" y="44" width="88" height="42" rx="6"/>
    <rect x="522" y="110" width="192" height="42" rx="6" stroke-dasharray="4 3"/>
    <rect x="522" y="160" width="192" height="40" rx="6" stroke-dasharray="4 3"/>
    <rect x="510" y="262" width="216" height="52" rx="8" stroke="#c98a2b" stroke-width="1.8" stroke-dasharray="6 4"/>
  </g>
  <g font-family="ui-monospace, Menlo, monospace" fill="currentColor">
    <text x="14" y="20" font-size="10.5" fill="#8a93a3">TEMPLATES · rows, written once</text>
    <text x="24" y="50" font-size="12.5" font-weight="600">Agent</text>
    <text x="24" y="66" font-size="10" fill="#8a93a3">model, runtime, skills</text>
    <text x="24" y="130" font-size="12.5" font-weight="600">Environment</text>
    <text x="24" y="146" font-size="10" fill="#8a93a3">packages, repos, secrets</text>
    <text x="24" y="210" font-size="12.5" font-weight="600">Vault</text>
    <text x="24" y="226" font-size="10" fill="#8a93a3">secret overrides, per run</text>
    <text x="282" y="196" font-size="12.5" font-weight="600" fill="#2f8fb3">Fountain, at launch</text>
    <text x="282" y="212" font-size="10">merge env ∪ vault, vault wins</text>
    <text x="282" y="228" font-size="10">split: broker or sandbox</text>
    <text x="510" y="8" font-size="10.5" fill="#8a93a3">RUNS · the machine</text>
    <text x="522" y="36" font-size="12.5" font-weight="600" fill="#2f8fb3">Sandbox</text>
    <text x="530" y="62" font-size="10">Conversation</text>
    <text x="530" y="76" font-size="10" fill="#8a93a3">transcript</text>
    <text x="634" y="62" font-size="10">Conversation</text>
    <text x="634" y="76" font-size="10" fill="#8a93a3">shares it</text>
    <text x="530" y="128" font-size="10">env: config, placeholders</text>
    <text x="530" y="142" font-size="9.5" fill="#8a93a3">GITHUB_TOKEN=__github_token__</text>
    <text x="530" y="177" font-size="10">machine: built, warm,</text>
    <text x="530" y="191" font-size="10" fill="#8a93a3">metered, reclaimed</text>
    <text x="522" y="282" font-size="12.5" font-weight="600" fill="#c98a2b">Egress broker</text>
    <text x="522" y="298" font-size="10" fill="#c98a2b">hosted, when the broker is on</text>
    <text x="522" y="332" font-size="10" fill="#8a93a3">→ GitHub, model APIs, yours</text>
  </g>
  <g fill="none" stroke="currentColor" stroke-width="1.4" marker-end="url(#pr-a)">
    <path d="M210,56 H508"/>
    <path d="M210,136 H488 V180"/>
    <path d="M210,150 H244 V190 H268"/>
    <path d="M210,216 H244 V222 H268"/>
    <path d="M466,200 H496 V130 H520"/>
  </g>
  <g fill="none" stroke="#c98a2b" stroke-width="1.6" marker-end="url(#pr-b)">
    <path d="M368,242 V290 H508"/>
    <path d="M618,212 V260"/>
  </g>
  <g font-family="ui-monospace, Menlo, monospace" font-size="10" fill="#8a93a3">
    <text x="300" y="50">runs as a conversation</text>
    <text x="300" y="130">builds the machine</text>
    <text x="418" y="120">placeholders</text>
    <text x="380" y="284" fill="#c98a2b">values, per conversation</text>
    <text x="612" y="244" fill="#c98a2b" text-anchor="end">HTTPS_PROXY, only exit</text>
  </g>
</svg>
<figcaption><b>Three templates, one machine.</b> Agent, Environment and Vault are rows you write once. When a Conversation starts, Fountain builds the sandbox from the Environment and runs the Agent on it. Several Conversations can share one machine. On a hosted account with the egress broker on, a bound secret goes to the broker and the sandbox gets a placeholder; the sandbox reaches the internet only through the broker, which attaches the value. On any other account, the merged secrets enter the sandbox as environment variables.</figcaption>
</figure>

A Conversation starts. At that moment Fountain merges the Environment's
secrets with the Vault's secrets. **The Vault wins on a key collision.** That
one rule is what makes the division into four usable and not merely tidy.
[About vaults](concepts/vault.md) sets it out.

What happens next depends on the account. On a self-hosted instance, and on a
hosted account without the egress broker, the merged secrets enter the
sandbox as environment variables. On a hosted account with the broker on, a
bound secret does not. The sandbox gets a placeholder, such as
`__github_token__`, and the broker puts the real value on each request to the
bound host. [Where a secret comes from](concepts/secrets.md) follows one
secret through both paths.

Why an API for this, when you can run an agent in a sandbox by hand? Because
the templates outlive the run. The machine, the secrets and the agent are
rows you can list, diff, share and launch from code. Because the identity and
the machine are separate, so one Environment can run as you, as a bot user,
or as a customer. And because a run is a thing with an id, a status, a
transcript and an event stream. A webhook, a cron job or another agent can
start one and follow it.

## Substitution

Each string value in an Agent config takes a `${VAR}` reference. Fountain
resolves it from the merged environment and vault secrets at spawn time.

| Syntax | Result |
|---|---|
| `${VAR}` | The value of `VAR` from the merged map |
| `$$` | A literal `$` |

Substitution is recursive, so it works inside maps and lists. It is also
fail-complete. Fountain reports each absent variable at once, and not one for
each attempt.

## What Fountain does not have

There is no fifth primitive. Two things look like one and are not.

A **team** is not an object. A teammate is a Conversation bound to the reserved
channel `fountain:team`. Read
[Agents as teammates](concepts/teammates.md).

A **sandbox** is not an object you create. Fountain gives you one when a
Conversation starts. An ephemeral sandbox ends with its Conversation, and a
persistent one stays as the Agent's own machine. You can list a sandbox, put
a second Conversation on it with `sandbox_id`, and reset a persistent one.
Read [About sandboxes](concepts/sandboxes.md) and the
[Sandboxes section](api.md#sandboxes) of the API reference.

## Where to go next

- **Learn as you build.** The [guided tour](tour.md) uses all four to open a
  pull request, in about forty lines.
- **Understand one primitive.**
  [Environment](concepts/environment.md),
  [Vault](concepts/vault.md),
  [Agent](concepts/agent.md),
  [Conversation](concepts/conversation.md).
- **Understand the machinery.**
  [Where a secret comes from](concepts/secrets.md) follows a value from the
  master key to the process. [About sandboxes](concepts/sandboxes.md) covers
  the machine a run happens on. [Architecture](architecture.md) follows a
  prompt from the API call to the first token.
- **Look something up.** The [API reference](api.md) has each field.
  [Conversation states](reference/conversation-states.md) has the state table.
  The [glossary](reference/glossary.md) has the overloaded words.
