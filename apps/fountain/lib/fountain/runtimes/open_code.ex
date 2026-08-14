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

  alias Fountain.Runtimes.Model

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
  def default_env(%{model: model} = agent, inference_credentials) when is_binary(model) do
    provider_env(agent, inference_credentials) ++ [{"HOME", "/tmp"}]
  end

  def default_env(_, _inference_credentials), do: [{"HOME", "/tmp"}]

  defp provider_env(%{model: model}, inference_credentials) do
    case Model.provider(model) do
      "anthropic" -> env_pair("ANTHROPIC_API_KEY", :anthropic_api_key, inference_credentials)
      "openai" -> env_pair("OPENAI_API_KEY", :openai_api_key, inference_credentials)
      "google" -> env_pair("GEMINI_API_KEY", :gemini_api_key, inference_credentials)
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

  defp env_pair(name, key, inference_credentials) do
    case Map.get(inference_credentials, key) do
      nil -> []
      "" -> []
      value -> [{name, value}]
    end
  end

  # MCP servers travel in `session/new`'s `mcpServers` param on the ACP path
  # (#636); the `opencode.json` writer that used to live here served the bare
  # CLI. An agent opted out of ACP runs its legacy turns without MCP servers.
end
