defmodule Fountain.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude runtime — provisioning only.

  Turns speak ACP through the pinned `claude-agent-acp` adapter
  (`Fountain.Runtimes.ACP`); the CLI argv builder that used to live here went
  with the legacy spawn path. What remains is the half ADR 0014 deliberately
  kept: how credentials, skills and MCP servers get into the sandbox.

  The adapter runs on the Claude Agent SDK, which reads the same skills tree
  as the CLI (`/home/sprite/.claude/skills`, verified live 2026-08-10) and
  honours the same credential env vars.

  ## MCP servers are provisioned, not delivered over ACP (#837)

  ACP defines a session-scoped channel for MCP servers (`session/new`'s
  `mcpServers`), and `Fountain.Runtimes.ACP.Peer` sends the agent's servers
  there correctly (pinned by `peer_mcp_test.exs`). But `claude-agent-acp`
  (measured on 0.66–0.70) never launches stdio servers passed that way —
  reproduced standalone, upstream bug
  [agentclientprotocol/claude-agent-acp#883]. Until that is fixed, the
  session-scoped path delivers nothing.

  So `write_config/2` provisions the servers into the sandbox instead, as a
  project `.mcp.json` plus `enableAllProjectMcpServers` in
  `~/.claude/settings.json` — which the CLI loads via its `settingSources`.
  This path is verified working end-to-end (2026-08-19): the model calls
  `mcp__<server>__*` tools and gets results. It works on every provider (all
  share `HOME=/home/sprite`), and the `${VAR}` refs are already resolved
  because the caller hands us the substituted agent.

  When the upstream bug is fixed, the session-scoped path will start working
  too; at that point drop this provisioning to avoid double-registration
  (cf. the same lesson in `Fountain.Runtimes.Gemini`).
  """

  @behaviour Fountain.Runtimes

  @mcp_config "/home/sprite/.mcp.json"
  @settings "/home/sprite/.claude/settings.json"

  @impl true
  def skills_root, do: "/home/sprite/.claude/skills"

  @impl true
  def skills_sh_agent, do: "claude-code"

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

  @doc """
  Provision the agent's MCP servers into the sandbox (see the moduledoc for
  why this, not the ACP session-scoped channel). No servers → nothing written.
  """
  @impl true
  def write_config(_handle, nil), do: :ok
  def write_config(_handle, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(handle, %{mcp_servers: mcp_servers}) when is_map(mcp_servers) do
    # Project-scope config the CLI reads via settingSources; `mcp_servers` is
    # already the Claude-Code shape (`%{name => %{"command"/"args"/"env"...}}`)
    # with `${VAR}` refs resolved by the caller.
    :ok =
      Fountain.Sandbox.write_file(
        handle,
        @mcp_config,
        Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)
      )

    # Pre-approve the project's servers so the first turn does not stall on an
    # approval the sandbox has no human to answer. (Fountain's ACP peer also
    # auto-allows `session/request_permission`, but that only fires mid-turn;
    # pre-approval keeps the server connected from session start.)
    :ok =
      Fountain.Sandbox.write_file(
        handle,
        @settings,
        Jason.encode!(%{"enableAllProjectMcpServers" => true}, pretty: true)
      )

    :ok
  end

  def write_config(_handle, _agent), do: :ok
end
