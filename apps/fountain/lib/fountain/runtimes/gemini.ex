defmodule Fountain.Runtimes.Gemini do
  @moduledoc """
  Google Gemini CLI runtime.

  Argv shape:

      mode == :run       → gemini --output-format stream-json
      mode == :continue  → gemini --resume --output-format stream-json

  Gemini manages its own session state — `--resume` re-enters the most
  recent conversation in the workspace, so we don't pass a session id.
  `--output-format stream-json` is the line-delimited stream the worker
  tails.

  Auth: `GEMINI_API_KEY` exported into the sprite.
  """

  @behaviour Fountain.Runtimes

  # Run gemini from a workspace dir we own and have git-init'd; avoids
  # the noisy `[WARN] [MemoryDiscovery] EACCES at /home/sprite/.git`
  # message (gemini walks up from cwd looking for .git, and /home/sprite's
  # perms trip it).  Also gives MemoryDiscovery a real workspace root
  # to anchor on instead of crawling /home.
  @workdir "/tmp/gemini-workspace"

  # gemini runs with HOME=/tmp on the sprite, so its skill discovery
  # path is /tmp/.gemini/skills (NOT /home/sprite/.gemini/skills).
  @impl true
  def skills_root, do: "/tmp/.gemini/skills"

  @impl true
  def skills_sh_agent, do: "gemini-cli"

  @impl true
  def build_command(agent, _prompt, mode, _runtime_session_id, opts) do
    base = [
      "--output-format",
      "stream-json",
      # `yolo` auto-approves tool calls — matches claude's
      # `--dangerously-skip-permissions` and codex's
      # `--dangerously-bypass-approvals-and-sandbox`.
      "--approval-mode",
      "yolo"
    ]

    # Non-interactive gemini does NOT load MCP tools by default. The
    # `--allowed-mcp-server-names` flag is the explicit allow-list.
    mcp_args =
      case mcp_server_names(agent) do
        [] -> []
        names -> ["--allowed-mcp-server-names" | names]
      end

    resume = if mode == :continue, do: ["--resume"], else: []

    # Gemini has no --image flag. The @path syntax embedded in the prompt
    # text tells gemini-cli to include that file as multimodal context.
    prompt_suffix =
      case Keyword.get(opts, :images, []) do
        [] -> ""
        images -> "\n" <> Enum.map_join(images, "\n", fn {path, _mt} -> "@#{path}" end)
      end

    {"gemini", resume ++ base ++ mcp_args, [dir: @workdir, prompt_suffix: prompt_suffix]}
  end

  defp mcp_server_names(%{mcp_servers: m}) when is_map(m) and m != %{},
    do: m |> Map.keys() |> Enum.map(&to_string/1)

  defp mcp_server_names(_), do: []

  @impl true
  def default_env(_agent) do
    base =
      case Application.get_env(:fountain, :gemini_api_key) do
        nil -> []
        "" -> []
        key -> [{"GEMINI_API_KEY", key}]
      end

    # gemini-cli aborts during init if it can't rename
    # `~/.gemini/projects.json.tmp` → `projects.json`. The sprite user
    # can write into /home/sprite/.gemini at first glance (ACLs let `ls`
    # and most writes through), but rename across that boundary errors
    # out. /tmp side-steps it cleanly. Mirrors the same fix we needed
    # for opencode's `~/.opencode` access path.
    base ++ [{"HOME", "/tmp"}]
  end

  # Gemini reads user-scope MCP servers from `$HOME/.gemini/settings.json`,
  # under `mcpServers` (camelCase, same shape as Claude). Because we run
  # with HOME=/tmp, write there only — duplicating into /home/sprite
  # was making gemini register every MCP tool twice on startup and
  # spam the log with `Tool ... already registered. Overwriting.` lines.
  @impl true
  def write_config(_sprite, nil), do: :ok
  def write_config(_sprite, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(sprite, %{mcp_servers: mcp_servers}) do
    fs = Sprites.filesystem(sprite, "/")
    payload = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)
    Sprites.Filesystem.mkdir_p(fs, "/tmp/.gemini")
    Sprites.Filesystem.write(fs, "/tmp/.gemini/settings.json", payload)
    :ok
  end

  # Make sure the workspace exists and is a git repo; gemini's
  # MemoryDiscovery is happy as long as it finds *some* .git when it
  # walks up from cwd.
  @impl true
  def prepare_sprite(sprite, _agent, sprite_env) do
    script = """
    set -e
    if [ ! -d #{@workdir}/.git ]; then
      mkdir -p #{@workdir}
      cd #{@workdir}
      git init -q
      git config user.email aod@local
      git config user.name AoD
    fi
    """

    {_out, code} =
      Sprites.cmd(sprite, "bash", ["-lc", script],
        env: sprite_env,
        timeout: 30_000
      )

    if code == 0, do: :ok, else: {:error, {:gemini_workspace_init_exit, code}}
  end
end
