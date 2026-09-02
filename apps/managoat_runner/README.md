# Managoat.Runner

The self-hosted runner: a `Managoat.Sandbox` adapter whose transport is a
WebSocket that a daemon on the user's own machine dials *out* to the platform.
This package is the platform's end of that protocol: the connection process
that holds one daemon's socket, the adapter that turns sandbox operations
into requests over it, the sandbox-name shape that says which runner a
request goes to, and a fake daemon inside the BEAM that speaks the protocol
for tests.

```elixir
# The platform's supervision tree, or a consumer without a cluster:
children = [Managoat.Runner.Host.Local]

# config.exs
config :managoat_runner, host: Managoat.Runner.Host.Local

config :managoat_sandbox,
  adapters: %{sprites: Managoat.Sandbox.Sprites, runner: Managoat.Runner.Adapter}

# The socket route, after authenticating the daemon however the host does:
WebSockAdapter.upgrade(
  conn,
  Managoat.Runner.Connection,
  %{runner_id: runner_id, name: "mini", meta: %{owner: account_id}},
  timeout: 120_000
)

# Then it is a sandbox like any other. The runner id rides in the name.
name = Managoat.Runner.Names.for_runner(runner_id)
{:ok, handle} = Managoat.Sandbox.create(:runner, name)
{:ok, output, 0} = Managoat.Sandbox.exec(handle, "uname", ["-a"])
```

## The pieces

| Module | Role |
|---|---|
| `Managoat.Runner.Connection` | The `WebSock` handler for one daemon's socket. `call/3` sends a request from anywhere the host can route from and waits for the reply; unsolicited `stream` frames reach the owner of the command they belong to as the standard `Managoat.Sandbox` owner messages. Its moduledoc is the wire protocol. |
| `Managoat.Runner.Adapter` | `@behaviour Managoat.Sandbox` implemented as one request per callback. Advertises `:suspend` and `:attach`; every offline, disconnected or timed-out request is `{:unavailable, _}`, transient in the taxonomy. `host_path/2` maps `/home/sprite` onto the sandbox's real directory. |
| `Managoat.Runner.Names` | `runner-<32 hex>-<8 hex>`: the runner's UUID without dashes plus a random suffix. `for_runner/1` mints, `parse/1` recovers the id. Pure. |
| `Managoat.Runner.Host` | The behaviour the platform implements: what the connection and the adapter need that is not protocol. |
| `Managoat.Runner.Host.Local` | The reference host over a plain `Registry`, one node, no reaction to heartbeats or presence. The library's tests run against it. |
| `Managoat.Runner.Config` | Reads `config :managoat_runner, host: Module`. No default: a missing host raises a message naming the key. |
| `Managoat.Runner.FakeDaemon` | A daemon inside the BEAM speaking the exact protocol, in `lib/` so a host's tests and a consumer's tests can drive it. |

## The host behaviour

The connection process and the adapter need six things from the platform that
runs them, and none of them is protocol. `Managoat.Runner.Host` has exactly
those callbacks:

| Callback | When | Why |
|---|---|---|
| `register(runner_id, meta)` | the socket opens, from the connection process | one connection per runner; a second is refused and closed with 4409 |
| `unregister(runner_id)` | the socket closes, before `presence/3` | a subscriber that looks the runner up on the offline notice sees the truth |
| `whereis(runner_id)` | every `call/3` and `unsubscribe/3` | the connection process for a runner id, from any node the host spans |
| `online()` | `Adapter.list_all_names/0` | every connected runner with its `meta`; the reaper's whole view |
| `heartbeat(runner_id)` | every 20 seconds while the socket is up | a host that keeps a `last_seen_at` stamps it here |
| `presence(runner_id, :online \| :offline, meta)` | after register, after unregister | a host with a roster to refresh broadcasts here |

`meta` is an opaque map. The host puts what it needs in it when the connection
is opened (the init map's `:meta` key) and gets it back on `online/0` and
`presence/3`; the library never reads a key from it. A host may send
`{:runner_deleted, runner_id}` to the connection process, which closes the
socket with 4404. That message is part of the contract between host and
connection.

The host is named in config and read through `Managoat.Runner.Config`, not
passed on each call: the adapter is instantiated through the sandbox adapter
map with no arguments and has nowhere to receive one. The `WebSock` init map
may carry `host:` too, which overrides the configured one for that connection
and is what lets a test run two hosts side by side.

[Fountain](https://github.com/BinaryBourbon/fountain) implements the behaviour
in `Fountain.Runners.Host` over a Horde registry (cluster-wide), a `runners`
table (the heartbeat stamps `last_seen_at`) and Phoenix PubSub (presence
reaches the team surface). None of that is a dependency of this package.

## Wire protocol

Text frames, JSON objects. Platform → daemon, one request per `id`:

```json
{"id": 7, "op": "spawn", "name": "runner-…", "cmd": "…", "args": ["…"]}
```

Daemon → platform, one reply per request plus unsolicited stream frames:

```json
{"id": 7, "ok": true,  "result": {"session_id": "s-…"}}
{"id": 7, "ok": false, "error": "not_found", "detail": "…"}
{"stream": "stdout", "session_id": "s-…", "data": "<base64>"}
{"stream": "exit",   "session_id": "s-…", "code": 0}
{"stream": "stdout", "session_id": "s-…", "data": "…", "replay_for": 7}
```

The ops are `create get destroy list suspend resume write_file exec spawn
stdin stdin_close detach list_sessions attach`. The errors are the sandbox
contract's codes: `not_found`, `command_exited`, `not_supported`, `invalid`,
`unavailable` and `write_failed`; anything else becomes
`{:provider, :runner, {code, detail}}`.

A `spawn`/`attach` request names the owner and ref its session's frames
should reach; the subscription is installed *before* the reply is delivered
so no frame can slip past it. The daemon sends the reply first, then replays
the session's journal from byte zero tagged `replay_for` with that request's
id (those frames reach only the subscriber that request installed, so a
second attacher's replay never duplicates output at the first owner) and
then streams live frames, which reach every subscriber of the session.

The daemon has one attached bit per session. The connection sends `detach`
only when the last listener on this end is gone, so a second subscriber is
not silenced by the first one leaving. An `id` of `0` marks a request the
connection expects no reply to.

**Failure.** When the socket closes, every caller still waiting gets
`{:error, {:unavailable, :runner_disconnected}}` and every subscribed owner
gets `{:error, %{ref: ref}, :runner_disconnected}`: a transport failure in the
contract's terms, after which no `:exit` follows. Detached sessions on the
daemon keep running; that is what reattach is for. Close codes: 1003 for a
frame that is not JSON text, 4404 when the host deletes the runner, 4409 for
a second connection under the same id.

## The other end

The daemon is Go, in Fountain's CLI:
[`cli/internal/runner`](https://github.com/BinaryBourbon/fountain/tree/main/cli/internal/runner).
`conn.go` is its end of this protocol and `daemon_test.go` pins its reply
shapes. The two implementations must agree; `Managoat.Runner.FakeDaemon` is
the executable form of the protocol on this side, and the conformance suite
in `test/` runs the whole `Managoat.Sandbox` contract through it, the
connection process and the adapter, with no network and no database.

Fountain's own suite drives the same `FakeDaemon` against its Horde host, so a
change to the protocol here is caught on both sides before the Go daemon sees
it. The daemon is not published from this package; splitting the Go module out
is cheap later and has not been needed.

## Limitations

- **No egress policy.** The adapter does not advertise `:network_policy` and
  `apply_network_policy/2` answers `{:error, :not_supported}`: the machine is
  the user's and so is its network. A platform that requires a network policy
  before it will place a brokered conversation therefore cannot place one on a
  runner, which is the gap Fountain's ADR 0036 records and this extraction
  restates rather than closes.
- **No placement.** Which runner a *new* sandbox should be minted on is the
  host's policy (Fountain picks the most recently connected online runner for
  the account). The library only routes a name that already carries an id.
- **One connection per runner id**, held by one process. A cluster-wide host
  makes it reachable from every node; it does not make it redundant.

## Where it comes from

Extracted from [Fountain](https://github.com/BinaryBourbon/fountain) under
[ADR 0037](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0037-component-libraries.md);
the design is
[ADR 0022](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0022-self-hosted-runner-provider.md)
(the runner dials out, the runner id rides in the sandbox name, trusted mode)
and
[ADR 0036](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0036-firecracker-runner-backend.md)
(the microVM backend behind the same protocol).

Not yet on hex: this package depends on `managoat_sandbox`, which cannot
publish while its Sprites client is a git dependency. The sandbox library
graduates first; this one then pins its hex version.

## Licence

Apache-2.0. See `LICENSE`.
