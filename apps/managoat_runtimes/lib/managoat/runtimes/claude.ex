defmodule Managoat.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude runtime — provisioning only.

  Turns speak ACP through the pinned `claude-agent-acp` adapter
  (`Managoat.Runtimes.ACP`); the CLI argv builder that used to live here went
  with the legacy spawn path. What remains is the half ADR 0014 deliberately
  kept: how credentials, skills and MCP servers get into the sandbox.

  The adapter runs on the Claude Agent SDK, which reads the same skills tree
  as the CLI (`/home/sprite/.claude/skills`, verified live 2026-08-10) and
  honours the same credential env vars.

  ## MCP servers are provisioned, not delivered over ACP (#837)

  ACP defines a session-scoped channel for MCP servers (`session/new`'s
  `mcpServers`), and `Managoat.ACP.Peer` sends the agent's servers
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
  (cf. the same lesson in `Managoat.Runtimes.Gemini`). Registered as
  `:claude_mcp_via_files` in `Managoat.Runtimes.Quirks`, which carries the
  re-probe procedure and is guarded by a test that fails if this function
  disappears without the entry.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout

  @runtime "claude"

  # The project-scope config sits at the repo root the agent runs in, not
  # under the config directory — that is what makes it *project* scope.
  @mcp_config Path.join(Layout.cwd(@runtime), ".mcp.json")
  @settings Path.join(Layout.config_root(@runtime), "settings.json")

  @impl true
  def skills_root, do: Layout.skills_root(@runtime)

  @impl true
  def skills_sh_agent, do: Layout.skills_sh_agent(@runtime)

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
    #
    # Both writes are idempotent, so a transport blip on a sprite that has
    # only just booted is retried rather than failing the provision: the
    # first filesystem call into a fresh sprite timed out once in prod and
    # took the whole conversation with it.
    mcp_json = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)

    # Pre-approve the project's servers so the first turn does not stall on
    # an approval the sandbox has no human to answer. (Fountain's ACP peer
    # also auto-allows `session/request_permission`, but that only fires
    # mid-turn; pre-approval keeps the server connected from session start.)
    settings = Jason.encode!(%{"enableAllProjectMcpServers" => true}, pretty: true)

    with :ok <- write_retrying(handle, @mcp_config, mcp_json) do
      write_retrying(handle, @settings, settings)
    end
  end

  def write_config(_handle, _agent), do: :ok

  defp write_retrying(handle, path, body) do
    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.write_file(handle, path, body) end,
           label: "claude config write #{path}"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_config, path, reason}}
    end
  end

  @doc """
  Swaps `CLAUDE_CODE_OAUTH_TOKEN` for `ANTHROPIC_API_KEY` in an already-built
  env list — what a live turn asks for after the org has refused the OAuth
  token (#655). Left as-is (still carrying the doomed OAuth token) when no
  API key is on file: the caller decides what to tell the tenant when there
  is nothing to fall back to.

  Deliberately not folded into `default_env/2` as a "skip oauth" flag: that
  function runs at provisioning, before any turn has been attempted, so it
  has no way to know the token is bad. This is reached only after the specific
  ACP failure that says so.
  """
  @spec fall_back_to_api_key([{String.t(), String.t()}], %{atom() => String.t()}) ::
          [{String.t(), String.t()}]
  def fall_back_to_api_key(env, inference_credentials) do
    case Map.get(inference_credentials, :anthropic_api_key) do
      key when is_binary(key) and key != "" ->
        env
        |> Enum.reject(fn {k, _v} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
        |> List.keystore("ANTHROPIC_API_KEY", 0, {"ANTHROPIC_API_KEY", key})

      _ ->
        env
    end
  end
end
