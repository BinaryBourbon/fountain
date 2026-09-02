defmodule Managoat.Runtimes.OpenCode do
  @moduledoc """
  Opencode runtime — provisioning only. A multi-provider front-end; the
  model is selected over ACP (`session/set_model` via the peer) rather than
  argv since the `opencode run` builder went with the legacy spawn path.

  Turns speak ACP through opencode's own `acp` subcommand
  (`Managoat.Runtimes.ACP`), which starts a local HTTP server inside the
  sprite and drives it through opencode's SDK — a heavier process model than
  the stdio-only adapters, worth remembering when something hangs.

  Auth: depends on the provider in `agent.model`. We export whichever
  one of {ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY} matches.

  Heads-up: opencode is *not* pre-installed on the sprite base image —
  the first session on a new sprite will install it (10–30s longer than
  the other runtimes). Subsequent turns on the same sprite are normal
  speed. Registered as `:opencode_absent_from_base_image` in
  `Managoat.Runtimes.Quirks`.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout
  alias Managoat.Runtimes.Model

  @runtime "opencode"

  # opencode insists on being inside a git repo, and the sprite user cannot
  # `git init` in /home/sprite (work-tree perms). The workspace lives under
  # /tmp for that reason; `Managoat.Runtimes.Layout` owns the path, and the
  # ACP session runs in the same place because it reads the same row.
  @workdir Layout.cwd(@runtime)

  @impl true
  def skills_root, do: Layout.skills_root(@runtime)

  @impl true
  def skills_sh_agent, do: Layout.skills_sh_agent(@runtime)

  # HOME comes from the layout, so the directory opencode actually reads and
  # the directory Fountain writes its skills and instructions into are the
  # same one by construction.
  @impl true
  def default_env(%{model: model} = agent, inference_credentials) when is_binary(model) do
    provider_env(agent, inference_credentials) ++ Layout.home_env(@runtime)
  end

  def default_env(_, _inference_credentials), do: Layout.home_env(@runtime)

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
  def prepare_sandbox(handle, _agent, sprite_env) do
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

    case Managoat.Sandbox.exec(handle, "bash", ["-lc", install_script],
           env: sprite_env,
           timeout: 120_000
         ) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, code} -> {:error, {:opencode_install_exit, code}}
      {:error, reason} -> {:error, {:opencode_install, reason}}
    end
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
