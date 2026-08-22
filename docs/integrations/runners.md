# Self-hosted runners

A **runner** is a machine you own that runs the `fountain runner` daemon. It
can be a Mac mini under the desk, a home server or a GPU box.

It is the fourth [sandbox provider](sandbox-contract.md), and the one whose
control plane sits on *your* side of the network. The daemon dials out to
Fountain, holds one connection, and serves sandboxes for an agent whose
`sandbox_provider` is `runner`. There is no inbound port, it works behind NAT,
and nothing bills you by the minute.

Three reasons to want one.

- **Hardware Fountain cannot rent.** A Mac, for Xcode, a macOS-only toolchain
  or a local model on Apple silicon. A GPU. A machine on your LAN that holds
  something the agent needs.
- **State that stays.** The sandbox is the agent's memory. A machine that
  never shuts down has nothing to park and nothing to pay for.
- **A setup you own outright.** A self-hosted Fountain and your own machines
  need no vendor account at all.

[ADR 0022](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0022-self-hosted-runner-provider.md)
holds the design.

## At a glance

| | |
|---|---|
| Role | Sandbox provider, on a machine **you** own. |
| Turned on by | Nothing. It is on unless you set `SANDBOX_RUNNERS_ENABLED=false`. |
| Credential | None on the platform side. Each daemon uses the user's own full-scope API key. |
| Suspend | Stops the sandbox's processes. The directory stays. |
| Capabilities advertised | `:suspend`, `:attach` |
| Not advertised | Network policy, TTY, checkpoints, public URL. |
| Isolation | **None.** Trusted mode, and the agent's processes run as you. |

## Read this first: trusted mode

A runner sandbox is a **directory** on the machine. The agent's processes run
**as you**, with your network, your `PATH` and your tools. There is no VM, no
container, no `sandbox-exec`, and no egress policy between the agent and the
machine.

Fountain points `HOME` at the sandbox directory. Dotfiles, skills and `.env`
land there and stay with that one conversation. That is the whole of the
isolation.

Run it on a machine where you would hand a capable colleague a shell. The
protocol suits a container or VM mode, and nobody built one.

## Start one

```bash
fountain auth login                       # once; a full-scope API key
fountain runner                           # name = this machine's hostname
fountain runner --name mini --root ~/work/fountain-sandboxes
```

The daemon logs `runner: connected`, then stays in the foreground. Run it
under `launchd`, `systemd`, tmux, or whatever keeps a process up on that
machine. Ctrl-C stops it, and stops its sessions, because a runner's
processes belong to the daemon. It reconnects with backoff on any drop. It
gives up only when Fountain refuses the key, rejects the name, or has runners
switched off.

Then pin an agent to it. Use **Agents → edit → Sandbox provider → runner**,
or send `sandbox_provider: "runner"` to `POST /api/agents`.

Fountain places a new conversation for that agent on your **most recently
connected online runner**. Start one while no runner is online and it fails
plainly, with `no_runner_online` and HTTP 409. It does not queue.

Account → Runners, or `GET /api/runners`, lists each machine that has
connected, with live online status. `DELETE /api/runners/:id` forgets one. A
daemon that you left up reconnects and registers itself again.

## What the machine needs

It needs what the Sprites base image has, on the `PATH` of whoever starts the
daemon. That is `bash`, `git`, `node`, `npm`, `npx`, and `bun` for opencode.

Fountain installs the agent CLIs at provision, the way it does everywhere
else, with `npm install -g`. They go into the sandbox's own npm prefix,
`<sandbox>/.npm-global`, so Fountain writes nothing to your global node
install. The npm cache is your real `~/.npm`.

Fountain adds `/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin` and
`~/.bun/bin` to `PATH` when they exist. So a daemon that `launchd` starts with
a minimal environment still finds Homebrew.

Two things translate, and two do not.

| Fountain assumes | On a runner |
|---|---|
| `/home/sprite` is home. | Mapped to the sandbox directory. That holds for a file path, for a work directory **and for a command argument**. A `bash -lc` script that says `/home/sprite/.local/bin/x` lands in the sandbox. |
| `~` and a relative path. | The sandbox directory. |
| `packages.apt` in an environment. | Fails. A Mac has no `apt`, and the daemon does not translate to `brew`. Leave it empty, or use `setup_script`. |
| `networking_type: limited`. | Refused at launch. The provider does not advertise an egress policy, and it will not pretend. The conversation fails before a sandbox exists, with a `network` / `failed` event whose reason is `backend_lacks_network_policy`. The agent form shows the same warning when you pair the two. |

`/tmp` is the machine's `/tmp`. The gemini and opencode workspaces live there,
and each sandbox sees the same ones, as it does inside one Linux sandbox.

## How the contract maps

| Fountain operation | Runner mechanics |
|---|---|
| Create or adopt by name | `mkdir -p <root>/<name>`. It adopts a directory that already exists. A name is `runner-<runner id>-<short>`. The runner id rides in the name, because the sandbox contract hands the adapter nothing else. |
| `get` | A directory that is there means the sandbox runs. A `.fountain-suspended` marker means suspended. Absent means `not_found`. **A runner that is offline gives `{:unavailable, :runner_offline}`**, which is transient. A parked directory on a machine somebody switched off is still the agent's memory, and Fountain never mistakes it for gone. |
| Suspend and resume | Advertised. A suspend stops the sandbox's live processes, with SIGTERM and then SIGKILL, and leaves the marker. A resume removes it. An idle park costs nothing, and 0017's never-aged-out rule holds trivially. |
| Exec | The command, to completion, with the request's env over the sandbox env. A nonzero exit is data and never a raise. That includes 127, which is "not found", and 124, which is a timeout. |
| Streams and reattach | The daemon journals each session in memory from byte zero. `attach` replays the journal, tagged for the attacher alone, then tails. The exit code is the real one. A session outlives the socket, so a Fountain deploy in the middle of a turn reattaches to the same process. |
| Stdin | A pipe. `close_stdin` is a real EOF. A write after the exit gives `{:error, :command_exited}`. |
| List | The union over the runners that are **online right now**. The sandboxes of an offline runner are not in the view. The reaper already treats that as "skip, converge later", because it destroys only the names it sees. |
| Network policy, TTY, checkpoints, public URL | Not advertised. |

## On the team page and the API

A teammate whose sandbox lives on a runner shows where it runs. The roster
entry's `sandbox`, and that of each conversation object, carries `provider`,
one of `sprites|e2b|daytona|runner`. For a runner it also carries
`runner: {id, name, hostname, online, path}`. That names the machine and the
sandbox directory on it, so a client can say "on mac-mini · ~/…" and parse no
sandbox name.

Presence tells "asleep" apart from "the machine is off". While the runner is
not connected, the teammate is `machine_offline`, which reads as "machine
offline · wakes when the runner reconnects", and not `asleep` or `away`. A
message cannot wake it.

`POST /api/team/:agent_id/messages` and `POST /api/conversations/:id/prompts`
answer `503 runner_offline` with `Retry-After` until the daemon returns. That
is the shape `provisioning` uses.

A scheduled run on such a teammate waits the way a busy one waits.

A runner that connects or drops sends a `team` event on `/api/team/stream`. A
roster then notices that the machine came back, and polls for nothing.

## Configuration

| Variable | Default | Effect |
|---|---|---|
| `SANDBOX_RUNNERS_ENABLED` | `true` | The operator's opt-out. `false` hides the provider from the selection, and refuses a daemon connection with HTTP 404 at `/api/runners/ws`. |
| `SANDBOX_PROVIDER=runner` | — | Allowed as the instance default. It needs no credential. |

The daemon reads the usual CLI settings, which are `FOUNTAIN_API_KEY`,
`FOUNTAIN_BASE_URL` and `--profile`. It needs a **full-scope** key. A
sandbox's own per-conversation token cannot attach a machine that would then
run the account's agents.

## The wire protocol

One WebSocket, with JSON text frames, at `GET /api/runners/ws?name=…` with the
bearer key. Fountain sends the requests. The daemon replies by `id`, and
streams frames for the sessions that somebody asked about.

```text
→ {"id":7,"op":"spawn","name":"runner-…","cmd":"claude-agent-acp","args":[],"env":[["K","v"]],"dir":"/home/sprite","stdin":true,"detachable":true}
← {"id":7,"ok":true,"result":{"session_id":"s-…"}}
← {"stream":"stdout","session_id":"s-…","data":"<base64>","replay_for":7}   replay, to the requester only
← {"stream":"stdout","session_id":"s-…","data":"<base64>"}                  live, to every subscriber
← {"stream":"exit","session_id":"s-…","code":0}
→ {"id":8,"op":"stdin","session_id":"s-…","data":"<base64>"}
← {"id":8,"ok":false,"error":"command_exited"}
```

The ops are `create get destroy list suspend resume write_file exec spawn
stdin stdin_close detach list_sessions attach`. The errors are the contract's
codes: `not_found`, `command_exited`, `not_supported`, `invalid`,
`unavailable` and `write_failed`.

`Fountain.Runners.Connection` is the server end, and `cli/internal/runner` is
the daemon. `Fountain.Runners.FakeDaemon` is a daemon inside the BEAM that the
conformance suite runs against. It is the executable description that both ends
must agree with.

## Related

- [About sandboxes](../concepts/sandboxes.md), for why honest capabilities
  change the lifecycle.
- [The sandbox contract](sandbox-contract.md).
- [Change sandbox lifetimes](../guides/operate/sandbox-lifetime.md). A
  provider without `:suspend` would destroy on idle, and a runner does
  advertise it.
