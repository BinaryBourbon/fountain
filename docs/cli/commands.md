# All commands

<!-- GENERATED FILE. Do not edit.

     Rendered from the Cobra command tree by
     cli/internal/cmd/docsgen_test.go. Regenerate with:

         cd cli && go test ./internal/cmd/ -update-cli-docs

     Prose about what a command is for, and which one to reach for, belongs in
     the hand-written index at docs/cli.md. This file is the flag-complete
     description and nothing else. -->

Every command and every flag, generated from the binary. For what to reach for
and why, start at the [CLI reference](../cli.md).

## `fountain acp`

Speak the Agent Client Protocol on stdio (spawned by an editor)

Speak the Agent Client Protocol on stdio.

Not meant to be run by hand: an ACP-capable editor spawns this process and
talks JSON-RPC to it over the pipe. stdout carries the protocol and nothing
else; diagnostics go to stderr.

--agent names the Fountain agent a session runs — the protocol has no field
for it, so it is configured here. Point one editor entry at each agent you
want to reach.

--vault attaches a vault to every conversation this process opens. Vault
values override the agent's environment, so this is where per-entry secrets
belong — an identity the agent posts under, for instance. Two entries pointing
at the same agent with different vaults stay separate; the same secret in a
shared environment would not.

--environment provisions every conversation this process opens from that
environment instead of the agent's own. One agent config can then run under
several environments — one entry per environment — without duplicating the
agent. The vault still wins over it on key collision.

--permission decides what happens before the agent runs a tool. "ask" puts the
question in your editor, as an approval prompt, and the tool waits for your
answer; "auto_deny" refuses; the default, "auto_allow", runs it. Narrow it per
tool with key=verdict pairs — --permission execute=ask asks before shell
commands and allows the rest. Keys match the tool card's title first and then
ACP's kind (execute, edit, read, fetch, …), and a launch may only narrow what
the agent already allows.

Nobody answering is an answer: an unanswered prompt is denied after the
server's timeout, and so is one your editor dismisses or disconnects from. The
turn continues either way.

What it is, and is not: a control surface for a conversation running in a
Fountain sandbox — watch it, steer it, interrupt it. It has no access to the
files open in your editor, and the paths it reports are inside the sandbox,
not on your machine.

```
fountain acp [flags]
```

Options:

```
      --agent string         Fountain agent name or id to open sessions against
      --environment string   environment name or id to provision each session's conversation from, instead of the agent's own
      --log-level string     stderr log level: debug, info, warn, error (default "info")
      --permission string    what happens before the agent runs a tool: auto_allow, ask, auto_deny, or key=verdict pairs (for example "execute=ask")
      --vault string         vault name or id to attach to each session's conversation
```

## `fountain agent list`

List agents

```
fountain agent list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain agent show`

Show an agent

```
fountain agent show <id>
```

## `fountain apply`

Apply resource definitions from a YAML file or directory

```
fountain apply [flags]
```

Options:

```
  -f, --file string   path to YAML file or directory
      --var strings   extra variable for ${VAR} substitution (KEY=VAL, repeatable)
```

## `fountain auth login`

Authenticate and save credentials

```
fountain auth login
```

## `fountain auth logout`

Remove saved credentials

```
fountain auth logout
```

## `fountain auth whoami`

Print current user info

```
fountain auth whoami
```

## `fountain buzz agents list`

List hosted Buzz agents

```
fountain buzz agents list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain buzz agents set-access`

Change who may @-mention a hosted Buzz agent (restarts its harness)

Set buzz-acp's inbound author gate on a hosted Buzz agent and restart its
harness so it takes effect.

  --respond-to  owner-only | allowlist | anyone | nobody
  --allowlist   comma-separated 64-hex pubkeys (allowlist mode; required non-empty there)

Note: a later provider deploy from the Buzz desktop resends the desktop's own
record for the agent and overwrites what is set here.

```
fountain buzz agents set-access <name-or-id> [flags]
```

Options:

```
      --allowlist string    comma-separated 64-hex pubkeys admitted in allowlist mode
      --respond-to string   owner-only | allowlist | anyone | nobody
```

## `fountain conv delete`

Delete a conversation

```
fountain conv delete <id>
```

## `fountain conv interrupt`

Interrupt the running turn

```
fountain conv interrupt <id>
```

## `fountain conv list`

List conversations

```
fountain conv list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain conv prompt`

Send a prompt to a conversation and stream the result

```
fountain conv prompt <id> [flags]
```

Options:

```
  -i, --image strings   image file path (repeatable)
  -p, --prompt string   prompt text (required)
```

## `fountain conv show`

Show a conversation

```
fountain conv show <id>
```

## `fountain conv stream`

Stream conversation events

```
fountain conv stream <id>
```

## `fountain conv terminate`

Terminate a conversation

```
fountain conv terminate <id>
```

## `fountain env list`

List environments

```
fountain env list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain env show`

Show an environment

```
fountain env show <id>
```

## `fountain keys create`

Create a new API key

```
fountain keys create <name>
```

## `fountain keys list`

List API keys

```
fountain keys list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain keys revoke`

Revoke an API key

```
fountain keys revoke <id>
```

## `fountain run`

Run an agent (create conversation + stream until done)

```
fountain run <agent-name-or-id> [flags]
```

Options:

```
      --environment string    environment name or id to provision from, instead of the agent's own
  -p, --prompt string         prompt text (required)
      --sandbox string        sandbox id to attach to, instead of provisioning a new one
      --sandbox-mode string   ephemeral or persistent, instead of the agent's default
      --vault string          vault name or id
```

## `fountain runner`

Turn this machine into a sandbox provider for your Fountain agents

Run this machine as a self-hosted Fountain runner.

The daemon dials out to Fountain (no inbound port, works behind NAT), holds
the connection, and serves sandboxes for agents whose sandbox_provider is
"runner": each sandbox is a directory under --root, and the agent's processes
run here, as you, with HOME pointed at that directory. Idle sandboxes park by
stopping their processes; the directory — the agent's memory — stays.

Trusted mode, and the only mode: there is no VM, container or egress policy
between the agent and this machine. Run it on a machine you would hand a
capable colleague a shell on. See docs/integrations/runners.md.

Names are unique per account; a second daemon with the same name is refused.
The default name is this machine's hostname.

```
fountain runner [flags]
```

Options:

```
      --log-level string   debug|info|warn|error (default "info")
      --name string        runner name (default: the hostname, lowercased)
      --root string        sandbox root (default: ~/.fountain/runners/<name>/sandboxes)
```

## `fountain sandbox list`

List sandboxes

```
fountain sandbox list [flags]
```

Options:

```
      --json            output JSON
      --status string   comma-separated statuses to include (default: all)
```

## `fountain sandbox reset`

Destroy a persistent sandbox; the next launch builds a clean one

```
fountain sandbox reset <id>
```

## `fountain sandbox show`

Show a sandbox and the conversations on it

```
fountain sandbox show <id>
```

## `fountain vault create`

Create a vault

```
fountain vault create <name> [flags]
```

Options:

```
      --description string   vault description
```

## `fountain vault delete`

Delete a vault

```
fountain vault delete <id-or-name>
```

## `fountain vault delete-secret`

Delete a vault secret

```
fountain vault delete-secret <id-or-name> <key>
```

## `fountain vault list`

List vaults

```
fountain vault list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain vault set-secret`

Set a vault secret

```
fountain vault set-secret <id-or-name> <key> <value>
```

## `fountain vault show`

Show a vault

```
fountain vault show <id-or-name>
```

## `fountain webhooks create`

Create a webhook endpoint

```
fountain webhooks create <url> [flags]
```

Options:

```
      --description string   what this endpoint is for
      --event strings        event to subscribe to; repeatable. Defaults to conversation.turn.done, conversation.turn.failed and conversation.provision.failed
```

## `fountain webhooks delete`

Delete a webhook endpoint

```
fountain webhooks delete <id>
```

## `fountain webhooks deliveries`

Show recent delivery attempts

```
fountain webhooks deliveries <id> [flags]
```

Options:

```
      --json        output JSON
      --limit int   how many attempts to show (default 20)
```

## `fountain webhooks list`

List webhook endpoints

```
fountain webhooks list [flags]
```

Options:

```
      --json   output JSON
```

## `fountain webhooks pause`

Stop delivering to an endpoint

```
fountain webhooks pause <id>
```

## `fountain webhooks redeliver`

Send one recorded event again

```
fountain webhooks redeliver <id> <delivery-id>
```

## `fountain webhooks resume`

Start delivering to an endpoint again

```
fountain webhooks resume <id>
```

## `fountain webhooks rotate-secret`

Mint a new signing secret

```
fountain webhooks rotate-secret <id>
```

## `fountain webhooks show`

Show a webhook endpoint

```
fountain webhooks show <id>
```

## `fountain webhooks test`

Send a test event

```
fountain webhooks test <id>
```

## Global flags

Accepted by every command.

```
      --profile string   credentials profile name
```
