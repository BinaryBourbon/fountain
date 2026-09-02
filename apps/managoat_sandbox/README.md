# Managoat.Sandbox

One behaviour for the machine an agent runs in, three adapters that implement
it against hosted providers, and the conformance suite a fourth adapter runs
against.

```elixir
alias Managoat.Sandbox

{:ok, handle} = Sandbox.create(:sprites, "my-app-7f3a")
{:ok, output, 0} = Sandbox.exec(handle, "bash", ["-lc", "uname -a"])

{:ok, command} = Sandbox.spawn(handle, "bash", ["-lc", "tail -f /var/log/app"], owner: self())
receive do
  {:stdout, %{ref: ref}, data} when ref == command.ref -> IO.write(data)
end

:ok = Sandbox.destroy(handle)
```

Call sites never name an adapter module. Creation-side operations take a
provider atom; everything else dispatches on the `provider` tag carried by a
`Managoat.Sandbox.Handle` or `Managoat.Sandbox.Command`.

## The contract

`Managoat.Sandbox` is the `@behaviour`, the facade and the error taxonomy.
Its moduledoc is normative; the short version:

| Semantic | Rule |
|---|---|
| `create/2` | name-keyed and idempotent: a name that exists is adopted, not duplicated |
| `get/1` | `{:error, :not_found}` means definitively gone; anything transient is a different error |
| `destroy/1` | tolerates an already-gone sandbox |
| `list_all_names/0` | the whole account view, or `{:error, :truncated}`; never a partial view that looks whole |
| `exec/4` | blocks until exit and never raises; a nonzero exit is `{:ok, output, code}` |
| `spawn/4` | streams `{:stdout | :stderr | :exit | :error, %{ref: ref}, _}` frames to the owner, exactly one terminal frame, after all output |
| `write_stdin/2` | total: an exited command yields `{:error, :command_exited}` |
| `attach/3` | replays a detached session's output from byte zero, then tails |
| `apply_network_policy/2` | `allow: []` is deny-all, never a silent no-op |

Errors are the closed taxonomy `:not_found`, `:truncated`, `:not_supported`,
`:command_exited`, `{:rate_limited, retry_after}`, `{:unavailable, detail}`,
`{:denied, detail}`, `{:invalid, detail}`, `{:restore_failed, detail}`,
`{:write_failed, detail}` and `{:provider, provider, detail}`.
`Managoat.Sandbox.Retry.transient?/1` classifies them, and
`Managoat.Sandbox.Retry.with_backoff/2` is bounded exponential backoff for
the idempotent calls (never wrap a non-idempotent one in it).

Capabilities (`capabilities/0`) say what an adapter can do beyond the
required operations: `:suspend`, `:network_policy`, `:checkpoint`, `:attach`,
`:tty`, `:public_url`. A capability is a promise about the answer, and the
conformance suite checks the promise.

## The adapters

| Adapter | Provider | Notes |
|---|---|---|
| `Managoat.Sandbox.Sprites` | [sprites.dev](https://sprites.dev) via `sprites-ex` | scale-to-zero parking, detachable sessions with replay, deny-capable egress policy, public URLs |
| `Managoat.Sandbox.E2B` | [e2b.dev](https://e2b.dev) | name-keyed identity emulated through metadata; explicit TTL heartbeats; replay through in-sandbox journals |
| `Managoat.Sandbox.Daytona` | [daytona.io](https://daytona.io) or self-hosted | name-addressable; toolbox sessions replay from the start |

Each adapter reads its settings from this library's own otp_app through
`Managoat.Sandbox.Config`, never from the host application's:

```elixir
config :managoat_sandbox, Managoat.Sandbox.Sprites,
  token: System.get_env("SPRITES_TOKEN"),
  base_url: "https://api.sprites.dev",
  timeout_ms: 30_000,
  public_urls: true,
  checkpoint_creation_enabled: false

config :managoat_sandbox, Managoat.Sandbox.E2B,
  api_key: System.get_env("E2B_API_KEY"),
  base_url: "https://api.e2b.app",
  template: "base",
  user: "sprite"

config :managoat_sandbox, Managoat.Sandbox.Daytona,
  api_key: System.get_env("DAYTONA_API_KEY"),
  api_url: "https://app.daytona.io/api",
  snapshot: nil

config :managoat_sandbox, Managoat.Sandbox.Retry, base_ms: 250
```

A key set to `nil` counts as unset and takes the default. The adapter map is
config too, so a host can add its own adapters beside the three shipped ones:

```elixir
config :managoat_sandbox,
  adapters: %{
    sprites: Managoat.Sandbox.Sprites,
    e2b: Managoat.Sandbox.E2B,
    daytona: Managoat.Sandbox.Daytona,
    runner: MyApp.Sandbox.Runner
  }
```

Which of the registered providers a deployment may *use* (is the credential
set, has an operator switched one off, which is the default) is the host's
policy. The library answers only which module serves an atom.

## Writing a fourth adapter

The conformance suite is the tutorial. It ships in `lib/`, not `test/`, so a
consumer can run it from its own suite:

```elixir
defmodule MyApp.Sandbox.RunnerConformanceTest do
  use Managoat.Sandbox.ConformanceCase,
    adapter: MyApp.Sandbox.Runner,
    fixtures: %{
      exec_ok: {"bash", ["-lc", "echo hello"], "hello"},
      exec_fail: {"bash", ["-lc", "echo oops; exit 3"], 3},
      spawn_ok: {"bash", ["-lc", "echo hello"]},
      spawn_stay: {"bash", ["-lc", "echo ready; cat"]}
    }
end
```

`fixtures` supplies the adapter-appropriate command vocabulary; an optional
`name: {Mod, :fun, args}` mints sandbox names when the adapter needs a
particular shape. The suite pins create idempotency, the not-found versus
transient distinction, destroy tolerance, full-view listing, exec-never-raises,
the owner-message frame contract with exactly one terminal frame, stdin-write
totality, attach replay-from-start and suspend/resume totality.

`Managoat.Sandbox.Fake` is the reference implementation: a real, in-memory
adapter whose commands are actual processes emitting the frames, passing the
suite in full. Read it before writing an adapter, and use it to drive a
provisioning path without a network.

Then, in order:

1. Implement `@behaviour Managoat.Sandbox`. Keep the provider's secrets out of
   `Handle.private` inspection (the struct already excludes it from `Inspect`).
2. Normalize every provider error into the taxonomy in an `errors.ex`, so
   `Retry.transient?/1` classifies it right.
3. Register the module in the adapter map.
4. Run the conformance case against it, with `Req.Test` stubs for the
   provider's API.

## Where it comes from

Extracted from [Fountain](https://github.com/BinaryBourbon/fountain) under
[ADR 0037](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0037-component-libraries.md);
the design is
[ADR 0018](https://github.com/BinaryBourbon/fountain/blob/main/decisions/0018-sandbox-provider-abstraction.md).
Fountain's self-hosted runner adapter implements this behaviour from outside
the package, which is what the behaviour is for.

Not yet on hex: the Sprites client is a git dependency
(`superfly/sprites-ex`), and hex refuses those. Graduation needs a hex release
of that client or a vendored one.

## Licence

Apache-2.0. See `LICENSE`.
