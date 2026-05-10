defmodule Fountain.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude Code CLI runtime.

  Argv shape mirrors AoD's Python build_claude_command:
      claude --dangerously-skip-permissions --print --verbose
             --output-format stream-json
             (--session-id | --resume) <id>

  The prompt is piped on stdin by the spawn caller. ANTHROPIC_API_KEY is
  exported into the sprite environment.
  """

  @behaviour Fountain.Runtimes

  @impl true
  def skills_root, do: "/home/sprite/.claude/skills"

  @impl true
  def skills_sh_agent, do: "claude-code"

  @impl true
  def build_command(_agent, _prompt, mode, runtime_session_id, opts) do
    if mode == :continue and is_nil(runtime_session_id) do
      raise ArgumentError, "mode=:continue requires runtime_session_id"
    end

    flag = if mode == :continue, do: "--resume", else: "--session-id"

    base_args = [
      "--dangerously-skip-permissions",
      "--print",
      "--verbose",
      "--output-format",
      "stream-json",
      flag,
      runtime_session_id || ""
    ]

    # The claude CLI has no --image flag. Append image file paths to the
    # stdin prompt so Claude can use its Read tool to load them visually.
    prompt_suffix =
      case Keyword.get(opts, :images, []) do
        [] ->
          ""

        images ->
          paths = Enum.map_join(images, "\n", fn {path, _mt} -> path end)
          "\n\n[Attached images — read each file path to view:\n#{paths}]"
      end

    {"claude", base_args, [prompt_suffix: prompt_suffix]}
  end

  @impl true
  def default_env(_agent) do
    # OAuth token takes precedence — it bills against a Claude.ai
    # subscription (Pro/Team) instead of metered API usage. When set, we
    # do NOT also export ANTHROPIC_API_KEY: claude prefers the oauth
    # path, but mixing the two has caused observable surprises (auth
    # picked from the wrong env var, depending on CLI version), so we
    # pick exactly one here.
    oauth = Application.get_env(:fountain, :claude_code_oauth_token)
    api_key = Application.get_env(:fountain, :anthropic_api_key)

    cond do
      is_binary(oauth) and oauth != "" -> [{"CLAUDE_CODE_OAUTH_TOKEN", oauth}]
      is_binary(api_key) and api_key != "" -> [{"ANTHROPIC_API_KEY", api_key}]
      true -> []
    end
  end

  @impl true
  def write_config(_sprite, nil), do: :ok
  def write_config(_sprite, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(sprite, %{mcp_servers: mcp_servers}) do
    fs = Sprites.filesystem(sprite, "/")
    payload = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)
    Sprites.Filesystem.write(fs, "/home/sprite/.claude.json", payload)
    :ok
  end
end
