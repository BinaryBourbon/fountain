# Self-hosted runners

A **runner** is a machine you own, such as a Mac mini under the desk, a home
server or a GPU box, running the `fountain runner` daemon. It is the fourth
[sandbox provider](sandbox-contract.md), and the one whose control plane
sits on *your* side of the network: the daemon dials out to Fountain, holds
one connection, and serves sandboxes for agents whose `sandbox_provider` is
`runner`. No inbound port, works behind NAT, nothing billed by the minute.

Three reasons to want one.

- **hardware Fountain cannot rent**, such as a Mac (Xcode, macOS-only toolchains,
  Apple-silicon local models), a GPU, a machine on your LAN with things worth
  reaching;
- **state that just stays**, since the sandbox is the agent's memory and a machine
  that never shuts down has nothing to park and nothing to pay for;
- **a fully sovereign setup**, meaning a self-hosted Fountain plus your own machines
  needs no vendor account at all.

The design is [ADR 0022](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0022-self-hosted-runner-provider.md).

## Read this first: trusted mode

A runner sandbox is a **directory** on the machine, and the agent's
processes run **as you**, with your network, your `PATH`, your tools. There
is no VM, no container, no `sandbox-exec`, no egress policy between the
agent and the machine. `HOME` is pointed at the sandbox directory (so
dotfiles, skills and `.env` land there and stay per-conversation), and that is
the whole of the isolation.

Run it on a machine you would hand a capable colleague a shell on. A
container/VM mode is compatible with the protocol and is not built.

## Start one

```bash
fountain auth login                       # once; a full-scope API key
fountain runner                           # name = this machine's hostname
fountain runner --name mini --root ~/work/fountain-sandboxes
```

The daemon logs `runner: connected` and stays in the foreground; run it under
`launchd`, `systemd`, tmux, or whatever keeps a process up on that machine.
Ctrl-C stops it (and its sessions; a runner's processes belong to the
daemon). It reconnects with backoff on any drop, and gives up only when
Fountain refuses the key, rejects the name, or has runners switched off.

Then pin an agent to it: **Agents → edit → Sandbox provider → runner**, or
`sandbox_provider: "runner"` on `POST /api/agents`. New conversations for
that agent are placed on your **most recently connected online runner**;
starting one while none is online fails plainly (`no_runner_online`, HTTP
409) rather than queueing.

Account → Runners (`GET /api/runners`) lists every machine that has
connected, with live online status; `DELETE /api/runners/:id` forgets one
(a daemon left running reconnects and re-registers on its own).

## What the machine needs

The same things the Sprites base image has, on `PATH` for the user running
the daemon: `bash`, `git`, `node`/`npm`/`npx`, and `bun` for opencode. The
agent CLIs are installed by provisioning the way they are everywhere else
(`npm install -g`), into the sandbox's own npm prefix
(`<sandbox>/.npm-global`), so nothing is written to your global node
install; the npm cache is your real `~/.npm`. `/opt/homebrew/bin`,
`/usr/local/bin`, `~/.local/bin` and `~/.bun/bin` are added to `PATH` when
they exist, so a `launchd`-started daemon with a minimal environment still
finds Homebrew.

Two things translate and two do not:

| Fountain assumes | On a runner |
|---|---|
| `/home/sprite` is home | Mapped to the sandbox directory, in file paths, working directories **and command arguments** (a `bash -lc` script that says `/home/sprite/.local/bin/x` lands inside the sandbox) |
| `~` / relative paths | The sandbox directory |
| `packages.apt` in an environment | Fails, because there is no `apt` on a Mac and the daemon does not translate to `brew`. Leave it empty or use `setup_script` |
| `networking_type: limited` | Fails to provision, because the provider does not advertise egress policy and will not pretend |

`/tmp` is the machine's `/tmp` (the gemini/opencode workspaces live there,
shared across sandboxes, as they do inside a single Linux sandbox).

## How the contract maps

| Fountain operation | Runner mechanics |
|---|---|
| Name-keyed create/adopt | `mkdir -p <root>/<name>`; an existing directory is adopted. Names are `runner-<runner id>-<short>`, and the runner id rides in the name because the sandbox contract hands the adapter nothing else |
| `get` | directory present → running; a `.fountain-suspended` marker → suspended; absent → `not_found`; **runner offline → `{:unavailable, :runner_offline}`**, which is transient. A parked directory on a switched-off machine is still the agent's memory and is never mistaken for gone |
| Suspend / resume | Advertised: suspend stops the sandbox's live processes (SIGTERM, then SIGKILL) and leaves the marker; resume removes it. Idle parking costs nothing and 0017's never-aged-out rule holds trivially |
| Exec | The command, to completion, with the request's env over the sandbox env; a nonzero exit, including "not found" (127) and a timeout (124), is data and never a raise |
| Streaming / reattach | Every session is journaled in the daemon's memory from byte zero; `attach` replays the journal (tagged for the attacher only), then tails; the exit code is the real one. Sessions outlive the socket, so a Fountain deploy mid-turn reattaches to the same process |
| Stdin | A pipe; `close_stdin` is a real EOF; a write after exit is `{:error, :command_exited}` |
| Listing | The union over the runners **online right now**. An offline runner's sandboxes are not in the view, which the reaper already treats as "skip, converge later", since it only destroys names it sees |
| Network policy, TTY, checkpoints, public URL | Not advertised |

## On the team page and API

A teammate whose sandbox lives on a runner shows where it runs: the roster
entry's (and every conversation object's) `sandbox` carries `provider`
(`sprites|e2b|daytona|runner`) and, for runners, `runner: {id, name,
hostname, online, path}`, naming the machine and the sandbox directory on it, so a
client can say "on mac-mini · ~/…" without parsing the sandbox name.
Presence tells "asleep" from "the machine is off": while the runner is not
connected the teammate is `machine_offline` ("machine offline · wakes when
the runner reconnects") rather than `asleep`/`away`, because a message
cannot wake it. `POST /api/team/:agent_id/messages` (and `POST
/api/conversations/:id/prompts`) answer `503 runner_offline` with
`Retry-After` until the daemon is back, the same shape as `provisioning`. A
scheduled run on such a teammate waits the same way a busy one does. A
runner connecting or dropping sends a `team` event on `/api/team/stream`, so
a roster notices the machine came back without polling.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `SANDBOX_RUNNERS_ENABLED` | `true` | Operator opt-out. `false` hides the provider from selection and refuses daemon connections (HTTP 404 at `/api/runners/ws`) |
| `SANDBOX_PROVIDER=runner` | — | Allowed as the instance default; needs no credential |

The daemon reads the usual CLI settings (`FOUNTAIN_API_KEY`,
`FOUNTAIN_BASE_URL`, `--profile`). It needs a **full-scope** key, since a
sandbox's per-conversation token cannot attach a machine that would then run
the account's agents.

## The wire protocol

One WebSocket, JSON text frames, `GET /api/runners/ws?name=…` with the
bearer key. Fountain sends requests, the daemon replies by `id` and streams
frames for sessions someone asked about:

```text
→ {"id":7,"op":"spawn","name":"runner-…","cmd":"claude-agent-acp","args":[],"env":[["K","v"]],"dir":"/home/sprite","stdin":true,"detachable":true}
← {"id":7,"ok":true,"result":{"session_id":"s-…"}}
← {"stream":"stdout","session_id":"s-…","data":"<base64>","replay_for":7}   replay, to the requester only
← {"stream":"stdout","session_id":"s-…","data":"<base64>"}                  live, to every subscriber
← {"stream":"exit","session_id":"s-…","code":0}
→ {"id":8,"op":"stdin","session_id":"s-…","data":"<base64>"}
← {"id":8,"ok":false,"error":"command_exited"}
```

Ops: `create get destroy list suspend resume write_file exec spawn stdin
stdin_close detach list_sessions attach`. Errors are the contract's codes
(`not_found`, `command_exited`, `not_supported`, `invalid`, `unavailable`,
`write_failed`). `Fountain.Runners.Connection` is the server end,
`cli/internal/runner` the daemon, and `Fountain.Runners.FakeDaemon`, an
in-BEAM daemon the conformance suite runs against, is the executable
description both must agree with.
