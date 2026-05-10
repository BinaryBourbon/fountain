defmodule Fountain.Runtimes.OpenCode do
  @moduledoc """
  Opencode CLI runtime — a multi-provider front-end. Unlike claude /
  codex / gemini whose argv is model-agnostic, opencode inlines the
  model into argv via `--model provider/model_id`.

  Argv shape:

      mode == :run       → opencode run --model <agent.model> --format json
      mode == :continue  → opencode run --model <agent.model> --format json --continue

  Auth: depends on the provider in `agent.model`. We export whichever
  one of {ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY} matches.

  Heads-up: opencode is *not* pre-installed on the sprite base image —
  the first session on a new sprite will install it (10–30s longer than
  the other runtimes). Subsequent turns on the same sprite are normal
  speed.
  """

  @behaviour Fountain.Runtimes

  # opencode insists on being inside a git repo. Putting the workspace
  # in /tmp side-steps the sprite user's lack of write access on
  # /home/sprite (which prevents `git init` from stat'ing the work tree).
  @workdir "/tmp/opencode-workspace"

  # opencode runs with HOME=/tmp (see default_env/1), so its skills
  # discovery path is rooted there.
  @impl true
  def skills_root, do: "/tmp/.config/opencode/skills"

  @impl true
  def skills_sh_agent, do: "opencode"

  @impl true
  def build_command(agent, _prompt, mode, _runtime_session_id, _opts) do
    base = [
      "run",
      "--model",
      agent.model,
      "--format",
      "json",
      "--dangerously-skip-permissions",
      "--dir",
      @workdir
    ]

    args = if mode == :continue, do: base ++ ["--continue"], else: base
    {"opencode", args, []}
  end

  @impl true
  def default_env(%{model: model} = agent) when is_binary(model) do
    provider_env(agent) ++ [{"HOME", "/tmp"}]
  end

  def default_env(_), do: [{"HOME", "/tmp"}]

  defp provider_env(%{model: model}) do
    case provider_of(model) do
      "anthropic" -> env_pair("ANTHROPIC_API_KEY", :anthropic_api_key)
      "openai" -> env_pair("OPENAI_API_KEY", :openai_api_key)
      "google" -> env_pair("GEMINI_API_KEY", :gemini_api_key)
      _ -> []
    end
  end

  # opencode isn't on the default sprite image. Install it via bun and
  # symlink into ~/.local/bin (which the sprite's default PATH includes;
  # bun's own global bin at /.sprite/languages/bun/bin is not on PATH).
  # Idempotent — `command -v` short-circuits on subsequent calls.
  @impl true
  def prepare_sprite(sprite, _agent, sprite_env) do
    install_script = """
    set -e

    # Install opencode + symlink onto PATH if missing.  We hardcode the
    # absolute path because the runtime overrides HOME=/tmp at spawn time
    # (see comment below), so `~/.local/bin` can resolve to /tmp/.local
    # depending on when the script runs.
    if ! command -v opencode >/dev/null; then
      bun install -g opencode-ai
      mkdir -p /home/sprite/.local/bin
      ln -sf "$(bun pm bin -g)/opencode" /home/sprite/.local/bin/opencode
    fi

    # opencode insists on running inside a git repo, and the sprite user
    # can't `git init` directly in $HOME (work-tree perms). Use /tmp;
    # mirrors @workdir in build_command so `opencode run --dir ...`
    # finds it.
    if [ ! -d #{@workdir}/.git ]; then
      mkdir -p #{@workdir}
      cd #{@workdir}
      git init -q
      git config user.email aod@local
      git config user.name AoD
    fi

    # Pre-warm the sqlite migration. opencode prints
    # "Performing one time database migration..." on the first
    # subcommand that touches its storage layer; doing it during
    # provision keeps the conversation log clean.
    if [ ! -f /tmp/.local/share/opencode/opencode.db ]; then
      opencode auth list >/dev/null 2>&1 || true
    fi
    """

    {_out, code} =
      Sprites.cmd(sprite, "bash", ["-lc", install_script],
        env: sprite_env,
        timeout: 120_000
      )

    if code == 0, do: :ok, else: {:error, {:opencode_install_exit, code}}
  end

  defp provider_of(model) do
    case String.split(model, "/", parts: 2) do
      [p, _] -> p
      _ -> nil
    end
  end

  defp env_pair(name, config_key) do
    case Application.get_env(:fountain, config_key) do
      nil -> []
      "" -> []
      value -> [{name, value}]
    end
  end

  # opencode reads `~/.config/opencode/opencode.json`; MCP servers go under
  # `mcp` and each entry needs `type: "local"`, `command` as an ARRAY,
  # and `environment` (not `env`).  We translate from the canonical
  # claude shape stored on the agent.
  @impl true
  def write_config(_sprite, nil), do: :ok
  def write_config(_sprite, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(sprite, %{mcp_servers: mcp_servers}) do
    fs = Sprites.filesystem(sprite, "/")
    Sprites.Filesystem.mkdir_p(fs, "/tmp/.config/opencode")
    Sprites.Filesystem.mkdir_p(fs, "/home/sprite/.config/opencode")

    payload =
      Jason.encode!(
        %{
          "$schema" => "https://opencode.ai/config.json",
          "mcp" => Map.new(mcp_servers, &translate_mcp_entry/1)
        },
        pretty: true
      )

    # Write to both locations: the runtime overrides HOME=/tmp at spawn
    # time, so opencode actually reads /tmp/.config/opencode/opencode.json.
    # We keep the /home/sprite copy in sync for `opencode` invocations
    # outside our spawn (e.g. an operator shelling in).
    Sprites.Filesystem.write(fs, "/tmp/.config/opencode/opencode.json", payload)
    Sprites.Filesystem.write(fs, "/home/sprite/.config/opencode/opencode.json", payload)
    :ok
  end

  defp translate_mcp_entry({name, %{} = entry}) do
    cmd = Map.get(entry, "command")
    args = Map.get(entry, "args", [])

    {name,
     %{
       "type" => "local",
       "command" => [cmd | args],
       "environment" => Map.get(entry, "env", %{}),
       "enabled" => true
     }}
  end
end
