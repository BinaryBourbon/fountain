defmodule Fountain.Runtimes.ACP do
  @moduledoc """
  Whether a turn speaks the Agent Client Protocol, and what to spawn if it does.

  Gate 2 of [0014](decisions/0014-agent-client-protocol.md). This module is the
  *provisioning* side of the ACP path — which adapter, which version, how it
  gets into the sprite — and it deliberately holds no protocol state. The
  session lives in `Fountain.Runtimes.ACP.Peer`, for one turn, and dies with it.

  ## The only path

  Every supported runtime speaks ACP, unconditionally. The per-agent
  `metadata["acp"]` flag is dead: it began as gate 2's opt-in, flipped to an
  opt-out when ACP became the default, and was removed when the legacy spawn
  path for these runtimes was deleted — there is nothing left to opt out
  into. `build_command/5` survives only on runtimes that are not here
  (gemini, #659).

  ## Which runtimes

  All four have adapter entries; claude, codex and opencode are shippable and
  gemini is held back (#659). The two ends of the resumption story gate 1
  mapped are claude and gemini:

  Claude advertises `sessionCapabilities.resume`, so a turn costs a handshake
  and nothing else. Gemini advertises only `loadSession`, and `session/load`
  replays the entire conversation before responding — under one connection per
  turn that is the whole history re-streamed on every turn after the first.
  `Peer`'s replay-discard exists for exactly this, and Gemini is the runtime
  that actually exercises it.

  Converting Gemini is still worth it despite the replay, because its legacy
  resume is the worst thing we ship: `gemini --resume` re-enters "the most
  recent conversation in the workspace" (`gemini.ex:14-17`), which is correct
  only while one conversation ever runs per workspace — an invariant held by
  accident and asserted by no test. ACP names the session.

  **Gemini is converted but held back** (#659), and the reason is not ours to
  fix. `supported_runtimes/0` excludes it, so the per-agent flag cannot switch
  it on; the entry stays because the conversion is correct as far as it goes.

  Diagnosed against a live 0.53.0 on 2026-08-11 (#658). Turn 1 does write a
  session, to `$HOME/.gemini/tmp/<project>/chats/session-<ISO minute>-<first 8
  of the id>.jsonl`, and gemini's own `--list-sessions` finds it. **Loading it
  is what destroys it.** `session/load` builds a fresh config on the same
  session id *before* looking the session up, and that config's chat recorder
  takes its new-session branch: it computes the same file name — the id's first
  8 characters plus the current wall-clock minute — and appends a header and a
  `$set` carrying a `messages` array holding only its `<session_context>`
  bootstrap. Gemini's own reader treats a `$set.messages` as a **replacement**,
  and a user message beginning `<session_context>` is ignored content, so the
  file it just appended to now has no resumable content. It drops out of
  `listSessions()`, and `findSession` reports `-32603` / "No previous sessions
  found for this project" — about a session whose transcript is still sitting
  in the same file, above the line that erased it.

  That is why it looked random. The collision is bucketed by **minute**: a
  resume in the same minute as the previous turn poisons the session's own file
  and always fails; a minute later the poison lands in a sibling file and the
  load succeeds. The "2 successes to 4 failures" was a wall clock, not a race.
  Verified in both directions on live sprites.

  Waiting is not a workaround: a *second* consecutive resume failed even with a
  minute between every turn, and afterwards every older session file for that
  project was gone. One resume is not a conversation.

  It is also destructive rather than merely unreliable — a failed load leaves
  the session unloadable forever, so a user would lose the conversation, not
  just a turn. Fountain cannot work around this without reaching into another
  product's private store, so gemini stays blocked until upstream fixes it.

  Codex and OpenCode both advertise `loadSession` *and*
  `sessionCapabilities.resume`, so they resume as cheaply as Claude does. What
  differs is how ACP is reached: Codex through an adapter package we install
  and pin, OpenCode through its own `acp` subcommand — which starts a local
  HTTP server inside the sprite and drives it through opencode's SDK rather
  than being a plain stdio peer. It satisfies the protocol; it is simply a
  second process model to remember when something hangs.

  ## The adapter is pinned, and that is load-bearing

  Nothing about the runtime CLIs is version-pinned today: claude, codex and
  gemini arrive with the sprite base image and OpenCode is an unpinned
  `bun install -g`. That is survivable for a CLI whose argv changes slowly. It
  is not survivable for an adapter whose `initialize` response decides whether
  the feature works at all — an unpinned adapter can silently stop advertising
  `sessionCapabilities.resume` and downgrade every conversation to a full
  history replay per turn, with no error anywhere.

  So the version is pinned here, the install is idempotent, and the pin moves
  in a PR that says why.
  """

  alias Fountain.Agents.Agent

  # Per runtime: how ACP is reached, and where the agent should run.
  #
  # `package` nil means native support — the runtime speaks ACP itself and
  # arrives with the sprite base image, so there is nothing to install and
  # nothing we can pin. That is a real difference in exposure, not a
  # convenience: an adapter we install is a supply-chain surface we version,
  # and a native flag is a surface the image owner versions for us.
  @adapters %{
    # Verified at gate 1 (2026-08-09) and live on 2026-08-10: advertises
    # `loadSession: true` and `sessionCapabilities.resume`; `resumeSession`
    # reattaches without replaying while `loadSession` calls
    # `replaySessionHistory`.
    "claude" => %{
      bin: "claude-agent-acp",
      args: [],
      package: "@agentclientprotocol/claude-agent-acp",
      version: "0.66.0",
      cwd: "/home/sprite"
    },
    # Native: `gemini --acp`. Advertises `loadSession: true` and **no**
    # `sessionCapabilities`, so every turn after the first pays a full replay
    # that `Peer` discards. The cwd mirrors `Fountain.Runtimes.Gemini`'s
    # `@workdir` — gemini walks up from cwd looking for a `.git`, and
    # `Gemini.prepare_sprite/3` git-inits exactly this directory. Pointing it
    # at /home/sprite instead reintroduces the EACCES noise that workspace
    # exists to avoid.
    # Converted, verified, and **not shippable** — see `blocked`. Left in the
    # table rather than deleted because the conversion itself is correct: turn
    # 1 works end to end against a live agent. What does not work is gemini's
    # own session store, which erases a session in the act of loading it — the
    # moduledoc has the mechanism.
    "gemini" => %{
      bin: "gemini",
      args: ["--acp"],
      package: nil,
      version: nil,
      cwd: "/tmp/gemini-workspace",
      blocked: "#659"
    },
    # Adapter, on the Codex App Server. The `zed-industries/codex-acp` that
    # earlier drafts named is archived; this is its successor under the
    # protocol org. Auth is unchanged: `Codex.prepare_sprite/3` still runs
    # `codex login --with-api-key`, and OPENAI_API_KEY is still exported, so
    # the adapter inherits whichever the CLI would have used.
    "codex" => %{
      bin: "codex-acp",
      args: [],
      package: "@agentclientprotocol/codex-acp",
      version: "1.1.14",
      cwd: "/home/sprite"
    },
    # Native: `opencode acp`. Heavier than the others — the subcommand starts a
    # local HTTP server inside the sprite and drives it through opencode's own
    # SDK client, rather than being a plain stdio peer. It satisfies the
    # protocol, but it is a second process model to keep in mind when something
    # hangs. Nothing to install here: `OpenCode.prepare_sprite/3` already bun-
    # installs the binary and symlinks it onto PATH.
    "opencode" => %{
      bin: "opencode",
      args: ["acp"],
      package: nil,
      version: nil,
      cwd: "/tmp/opencode-workspace"
    }
  }

  @doc """
  Runtimes that may actually be switched on.

  Distinct from having an adapter entry. A runtime is listed here only when a
  full turn *and* a resume have been observed against a live agent — a
  conversion that resumes unreliably is worse than the legacy path it replaces,
  because the user gets a working first turn and an agent with no memory on
  every turn after.
  """
  @spec supported_runtimes() :: [String.t()]
  def supported_runtimes do
    @adapters |> Enum.reject(fn {_k, v} -> v[:blocked] end) |> Enum.map(&elem(&1, 0))
  end

  @doc """
  Runtimes with an adapter entry that are held back, and why.

  Public so the reason travels with the code rather than living only in an
  issue: `%{"gemini" => "#659"}`.
  """
  @spec blocked_runtimes() :: %{String.t() => String.t()}
  def blocked_runtimes do
    for {name, %{blocked: reason}} <- @adapters, into: %{}, do: {name, reason}
  end

  @doc "The npm package and version pinned for a runtime, or nil when native."
  @spec adapter_spec(String.t()) :: String.t() | nil
  def adapter_spec(runtime) do
    case @adapters[runtime] do
      %{package: nil} -> nil
      %{package: pkg, version: version} -> "#{pkg}@#{version}"
      _ -> nil
    end
  end

  @doc "The executable a runtime's ACP mode is reached through."
  @spec adapter_bin(String.t()) :: String.t() | nil
  def adapter_bin(runtime), do: get_in(@adapters, [runtime, :bin])

  @doc """
  Where the agent runs.

  ACP carries `cwd` in `session/new`, and it is the *agent's* working
  directory rather than ours — a runtime that walks up from it looking for a
  repo (gemini does) behaves differently depending on what we say here.
  """
  @spec cwd(String.t()) :: String.t()
  def cwd(runtime), do: get_in(@adapters, [runtime, :cwd]) || "/home/sprite"

  @doc """
  Whether this turn speaks ACP.

  A property of the runtime alone: supported runtimes always do, and for them
  the legacy spawn path no longer exists. A blocked or unknown runtime
  (gemini, #659) takes the legacy path — for those it is not a failure mode,
  it is the only path.

  Takes the runtime string, not the agent, because a conversation outlives
  its agent (deleting one nilifies `agent_id`) and the conversation row
  carries its own `runtime`. An `%Agent{}` is accepted for call sites that
  have one.
  """
  @spec enabled?(String.t() | Agent.t() | nil) :: boolean()
  def enabled?(%Agent{runtime: runtime}), do: enabled?(runtime)
  def enabled?(runtime) when is_binary(runtime), do: runtime in supported_runtimes()
  def enabled?(_), do: false

  @doc """
  Argv for the adapter.

  No prompt, no session id, no mode: unlike `build_command/5` this says nothing
  about the turn, because under ACP the turn is carried by `session/prompt`
  over the connection rather than by the process's arguments. That difference
  is the entire architectural change, and it is why this does not implement the
  `Fountain.Runtimes` behaviour.
  """
  @spec command(String.t()) :: {String.t(), [String.t()]}
  def command(runtime) do
    case @adapters[runtime] do
      %{bin: bin, args: args} -> {bin, args}
      _ -> raise ArgumentError, "runtime #{inspect(runtime)} has no ACP adapter"
    end
  end

  @doc """
  Install the pinned adapter into a sprite.

  Runs at provision time, with the rest of the package installs, because it
  needs unrestricted network — by the time a turn spawns, the network policy
  has been applied and an install would fail in a way that looks like a
  protocol bug.

  Idempotent on the exact pinned version: an image that already carries a
  different version is corrected rather than accepted, since "some adapter is
  installed" is precisely the state the pin exists to prevent.

  ## npm's global bin is not on the sprite's PATH

  Verified on a live sprite (2026-08-10): `npm prefix -g` is
  `/.sprite/languages/node/nvm/versions/node/v24.18.0`, whose `bin/` is **not**
  in the default PATH — `command -v claude-agent-acp` after a successful global
  install returns nothing. The spawn would then fail with `command not found`,
  which reads like a protocol bug and is not one.

  So we symlink into `/home/sprite/.local/bin`, which *is* on PATH. This is the
  same shape as `Fountain.Runtimes.OpenCode.prepare_sprite/3`, which hit the
  identical problem with bun's global bin, and the absolute path is hardcoded
  for the same reason it is there: `~` resolves against whatever `HOME` the
  caller happens to have.
  """
  @spec install(sprite :: any(), String.t(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def install(sprite, runtime, sprite_env)

  # Native ACP: the runtime speaks the protocol itself, and is already on the
  # sprite — gemini from the base image, opencode from
  # `OpenCode.prepare_sprite/3`'s bun install. Nothing to install, and for
  # gemini nothing we can pin either: the version floor is whatever the image
  # carries, which gate 1 recorded as an open exposure.
  def install(_sprite, runtime, _sprite_env) when runtime in ["gemini", "opencode"], do: :ok

  def install(sprite, runtime, sprite_env) do
    bin = adapter_bin(runtime)
    spec = adapter_spec(runtime)
    version = get_in(@adapters, [runtime, :version])

    script = """
    set -e
    want=#{version}
    bin=/home/sprite/.local/bin/#{bin}
    have=$("$bin" --version 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$have" != "$want" ]; then
      npm install -g --no-progress --silent #{spec}
      mkdir -p /home/sprite/.local/bin
      ln -sf "$(npm prefix -g)/bin/#{bin}" "$bin"
    fi
    "$bin" --version >/dev/null
    """

    case Sprites.cmd(sprite, "bash", ["-lc", script], env: sprite_env, timeout: 180_000) do
      {_out, 0} ->
        :ok

      {out, code} ->
        {:error, {:acp_adapter_install_exit, code, String.slice(to_string(out), 0, 500)}}
    end
  end

  @doc """
  An agent's MCP servers, in the shape `session/new` takes.

  Fountain stores them as Claude's own config map — `%{name => %{"command" =>
  …, "args" => […], "env" => %{…}}}`, or a `type`/`url` entry for HTTP and SSE.
  ACP takes an *array*, each entry carrying its own `name`, and — the detail
  that is easy to get silently wrong — **`env` and `headers` as arrays of
  `%{name, value}` rather than maps.** Passing a map there is accepted as JSON
  and then read as nothing: the server starts with no environment, which
  surfaces much later as a tool that cannot authenticate.

  Verified against the pinned adapter's own parser, which does
  `Object.fromEntries(server.env.map((e) => [e.name, e.value]))`.

  This is the *only* delivery path since #636 — the out-of-band per-runtime
  config writers (claude's `mcp add-json` loop, codex's `config.toml`,
  opencode's `opencode.json`) are gone. Gate 2 verified the protocol path
  live: server started, listed, called, env delivered.
  """
  @spec mcp_servers(Agent.t() | nil) :: [map()]
  def mcp_servers(%Agent{mcp_servers: servers}) when is_map(servers) and map_size(servers) > 0 do
    servers
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.map(fn {name, entry} -> mcp_server(to_string(name), entry) end)
  end

  def mcp_servers(_), do: []

  defp mcp_server(name, %{"type" => type} = entry) when type in ["http", "sse"] do
    %{name: name, type: type, url: entry["url"]}
    |> put_if_present(:headers, name_value_list(entry["headers"]))
  end

  defp mcp_server(name, entry) when is_map(entry) do
    # No `type` key at all: the adapter treats an entry without one as stdio,
    # and sending `type: "stdio"` puts it down the http/sse branch of its
    # parser, where it looks for a `url` that is not there.
    %{name: name, command: entry["command"], args: entry["args"] || []}
    |> put_if_present(:env, name_value_list(entry["env"]))
  end

  defp mcp_server(name, _), do: %{name: name, args: []}

  defp name_value_list(map) when is_map(map) and map_size(map) > 0 do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> %{name: to_string(k), value: to_string(v)} end)
  end

  defp name_value_list(list) when is_list(list) and list != [], do: list
  defp name_value_list(_), do: nil

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  @doc """
  The `initialize` params we send.

  **We declare no client filesystem or terminal capabilities.** `fs/*` and
  `terminal/*` are client-implemented, and ours would have to service them
  against the sprite rather than the Fountain server — 0014 names that as the
  likeliest source of a security finding and 0016 makes it its own gate. Gate 2
  declares nothing, so a well-behaved adapter never asks; the peer still
  answers anything that arrives, because an unanswered request blocks the agent
  and a blocked agent bills.
  """
  @spec initialize_params() :: map()
  def initialize_params do
    %{
      protocolVersion: 1,
      clientCapabilities: %{
        fs: %{readTextFile: false, writeTextFile: false},
        terminal: false
      }
    }
  end
end
