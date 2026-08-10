defmodule Fountain.Runtimes.ACP do
  @moduledoc """
  Whether a turn speaks the Agent Client Protocol, and what to spawn if it does.

  Gate 2 of [0014](decisions/0014-agent-client-protocol.md). This module is the
  *provisioning* side of the ACP path — which adapter, which version, how it
  gets into the sprite — and it deliberately holds no protocol state. The
  session lives in `Fountain.Runtimes.ACP.Peer`, for one turn, and dies with it.

  ## Off by default, per agent

  The flag is `agent.metadata["acp"] == true`. Metadata rather than a column
  because gate 2 is an experiment with an explicit exit — if gates 3 and 4 do
  not hold, this is deleted, and a migration would outlive the thing it was
  added for. A conversation started under the flag records nothing about it:
  the flag is read per turn, so flipping it mid-conversation switches the next
  turn and leaves the earlier ones rendering through the legacy path, which is
  exactly the A/B the gate asks for.

  ## One runtime

  Claude only, and that is gate 1's answer rather than a convenience. Gemini
  advertises `loadSession` and no `sessionCapabilities.resume`, and its
  `session/load` replays the entire conversation before responding — under one
  connection per turn that is the whole history re-streamed on every turn after
  the first. Claude advertises both, and its `session/resume` does not replay.
  Codex and OpenCode also advertise both and are gate 4's business.

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

  # Verified at gate 1 (2026-08-09): advertises `loadSession: true` and
  # `sessionCapabilities.resume`, and its `resumeSession` reattaches without
  # replaying while `loadSession` calls `replaySessionHistory`.
  @adapter_package "@agentclientprotocol/claude-agent-acp"
  @adapter_version "0.66.0"
  @adapter_bin "claude-agent-acp"

  @doc "The npm package and version this build is pinned to."
  @spec adapter_spec() :: String.t()
  def adapter_spec, do: "#{@adapter_package}@#{@adapter_version}"

  @doc "The executable name the pinned package installs."
  @spec adapter_bin() :: String.t()
  def adapter_bin, do: @adapter_bin

  @doc """
  Whether this turn should speak ACP.

  Both halves have to hold: the agent opted in, and its runtime is one gate 1
  cleared. A flag set on a Gemini agent is a no-op rather than an error — the
  legacy path is not a failure mode, it is the default.
  """
  @spec enabled?(Agent.t() | nil) :: boolean()
  def enabled?(%Agent{runtime: "claude", metadata: metadata}) when is_map(metadata) do
    Map.get(metadata, "acp") == true
  end

  def enabled?(_), do: false

  @doc """
  Argv for the adapter.

  No prompt, no session id, no mode: unlike `build_command/5` this says nothing
  about the turn, because under ACP the turn is carried by `session/prompt`
  over the connection rather than by the process's arguments. That difference
  is the entire architectural change, and it is why this does not implement the
  `Fountain.Runtimes` behaviour.
  """
  @spec command() :: {String.t(), [String.t()]}
  def command, do: {@adapter_bin, []}

  @doc """
  Install the pinned adapter into a sprite.

  Runs at provision time, with the rest of the package installs, because it
  needs unrestricted network — by the time a turn spawns, the network policy
  has been applied and an install would fail in a way that looks like a
  protocol bug.

  Idempotent on the exact pinned version: an image that already carries a
  different version is corrected rather than accepted, since "some adapter is
  installed" is precisely the state the pin exists to prevent.
  """
  @spec install(sprite :: any(), [{String.t(), String.t()}]) :: :ok | {:error, term()}
  def install(sprite, sprite_env) do
    script = """
    set -e
    want=#{@adapter_version}
    have=$(#{@adapter_bin} --version 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$have" != "$want" ]; then
      npm install -g --no-progress --silent #{adapter_spec()}
    fi
    """

    case Sprites.cmd(sprite, "bash", ["-lc", script], env: sprite_env, timeout: 180_000) do
      {_out, 0} ->
        :ok

      {out, code} ->
        {:error, {:acp_adapter_install_exit, code, String.slice(to_string(out), 0, 500)}}
    end
  end

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
