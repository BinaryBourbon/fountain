defmodule Fountain.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude Code CLI runtime.

  Argv shape mirrors AoD's Python build_claude_command:
      claude --model <model_id>
             --dangerously-skip-permissions --print --verbose
             --output-format stream-json
             (--session-id | --resume) <id>

  `--model` takes the bare id, so the canonical `anthropic/` prefix on
  `agent.model` is stripped (see `Fountain.Runtimes.Model`).

  The prompt is piped on stdin by the spawn caller. ANTHROPIC_API_KEY is
  exported into the sprite environment.
  """

  @behaviour Fountain.Runtimes

  alias Fountain.Runtimes.Model

  @impl true
  def skills_root, do: "/home/sprite/.claude/skills"

  @impl true
  def skills_sh_agent, do: "claude-code"

  @impl true
  def build_command(agent, _prompt, mode, runtime_session_id, opts) do
    if mode == :continue and is_nil(runtime_session_id) do
      raise ArgumentError, "mode=:continue requires runtime_session_id"
    end

    flag = if mode == :continue, do: "--resume", else: "--session-id"

    base_args =
      Model.model_args(agent) ++
        [
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
  def default_env(_agent, inference_credentials) do
    # OAuth token takes precedence — it bills against a Claude.ai
    # subscription (Pro/Team) instead of metered API usage. When set, we
    # do NOT also export ANTHROPIC_API_KEY: claude prefers the oauth
    # path, but mixing the two has caused observable surprises (auth
    # picked from the wrong env var, depending on CLI version), so we
    # pick exactly one here.
    oauth = Map.get(inference_credentials, :claude_code_oauth_token)
    api_key = Map.get(inference_credentials, :anthropic_api_key)

    cond do
      is_binary(oauth) and oauth != "" -> [{"CLAUDE_CODE_OAUTH_TOKEN", oauth}]
      is_binary(api_key) and api_key != "" -> [{"ANTHROPIC_API_KEY", api_key}]
      true -> []
    end
  end

  # MCP servers travel in `session/new`'s `mcpServers` param on the ACP path
  # (#636); the `claude mcp add-json --scope user` provisioning loop that used
  # to live here existed for the CLI, which the ACP adapter does not wrap. An
  # agent opted out of ACP (`metadata["acp"] == false`) therefore runs its
  # legacy turns without MCP servers — the opt-out is an emergency hatch, not
  # a configuration.
end
