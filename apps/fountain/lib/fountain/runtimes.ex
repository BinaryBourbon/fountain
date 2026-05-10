defmodule Fountain.Runtimes do
  @moduledoc """
  Behaviour every runtime (claude/codex/gemini/opencode) implements,
  plus a small dispatcher.
  """

  alias Fountain.Agents.Agent

  @type mode :: :run | :continue
  @type cmd :: {String.t(), [String.t()], keyword()}

  @doc """
  Build the argv (and any extra spawn opts like `:env`) for a single turn.

  - `mode == :run` for the first turn
  - `mode == :continue` for subsequent turns
  - `runtime_session_id` is the runtime CLI's own session id used for resume
  """
  @callback build_command(
              agent :: %Agent{},
              prompt :: String.t(),
              mode :: mode(),
              runtime_session_id :: String.t() | nil,
              opts :: keyword()
            ) :: cmd()

  @doc """
  Default env vars for the runtime — typically the inference credential
  for the chosen provider (e.g. `ANTHROPIC_API_KEY`).

  `inference_credentials` is a map of `%{provider_atom => plaintext_string}`
  decrypted from the user's `inference_credentials` row at conversation
  start (see `Fountain.InferenceCredentials.decrypted_for_user/2`).
  Providers the user hasn't set are simply absent from the map.
  """
  @callback default_env(
              agent :: %Agent{},
              inference_credentials :: %{atom() => String.t()}
            ) :: [{String.t(), String.t()}]

  @doc """
  Optionally write runtime-specific config files into the sprite at
  provision time (e.g. claude's `~/.claude.json` for MCP servers).
  No-op by default.
  """
  @callback write_config(sprite :: any(), agent :: %Agent{} | nil) :: :ok

  @doc """
  Optionally run any sprite-side bootstrap that has to happen *before*
  the first turn — e.g. codex needs `codex login --with-api-key` to
  persist credentials into `~/.codex/auth.json` since it doesn't read
  `OPENAI_API_KEY` from the live process env.

  Receives the same `sprite_env` pairs the spawn will use. Implementers
  pull whichever keys they need out of that list. No-op by default.
  """
  @callback prepare_sprite(
              sprite :: any(),
              agent :: %Agent{} | nil,
              sprite_env :: [{String.t(), String.t()}]
            ) :: :ok | {:error, term()}

  @doc """
  Absolute path on the sprite where inline skills are written as
  `<skills_root>/<name>/SKILL.md`. Each runtime points this at whatever
  directory its CLI scans for skills.
  """
  @callback skills_root() :: String.t()

  @doc """
  Identifier passed to `npx skills add ... --agent <id>` when installing
  a github-source skill. The skills.sh CLI uses this to choose the
  on-disk layout for the target runtime (claude-code, codex, gemini-cli,
  opencode).
  """
  @callback skills_sh_agent() :: String.t()

  @optional_callbacks default_env: 2, write_config: 2, prepare_sprite: 3

  @runtime_modules %{
    "claude" => Fountain.Runtimes.Claude,
    "codex" => Fountain.Runtimes.Codex,
    "gemini" => Fountain.Runtimes.Gemini,
    "opencode" => Fountain.Runtimes.OpenCode
  }

  @doc "Look up the runtime module for an agent's runtime string."
  def for_runtime(name) when is_binary(name) do
    case Map.fetch(@runtime_modules, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported runtime: #{name}"}
    end
  end
end
