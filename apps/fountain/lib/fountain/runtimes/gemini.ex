defmodule Fountain.Runtimes.Gemini do
  @moduledoc """
  Google Gemini CLI runtime.

  Provisioning only. Gemini speaks ACP since #659, so a turn spawns
  `gemini --acp` (`Fountain.Runtimes.ACP`) and the prompt, the model, the
  session id and the MCP servers all travel over the protocol rather than in
  argv. This module is what remains: the workspace, the skills paths, the
  settings file and `GEMINI_API_KEY`.

  `build_command/5` is gone with #941. It was the last implementation of that
  callback and the last place Fountain passed a vendor permission-bypass flag
  (`--approval-mode yolo`, matching the `--dangerously-*` flags claude, codex
  and opencode lost when their legacy spawn paths were deleted). Permissions
  are now a policy (#939) answered per tool over `session/request_permission`,
  with `ask` reaching a human (#940).

  Two things that lived in that argv and did not disappear with it:

  * **the model.** `--model` took the bare id, stripped from the canonical
    `google/` prefix. ACP pins it per session instead — gemini advertises
    `models`, so `Peer` sends `session/set_model` (see "model selection" in
    `acp/peer_test.exs`). The #553 regression it guarded against is still
    guarded, one layer down.
  * **`--resume`.** It re-entered "the most recent conversation in the
    workspace", correct only while one conversation ever ran per workspace.
    ACP names the session, which is the whole reason the conversion was worth
    doing.

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
  def default_env(_agent, inference_credentials) do
    base =
      case Map.get(inference_credentials, :gemini_api_key) do
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
  def write_config(_handle, nil), do: :ok
  def write_config(_handle, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(handle, %{mcp_servers: mcp_servers}) do
    payload = Jason.encode!(%{"mcpServers" => mcp_servers}, pretty: true)
    Fountain.Sandbox.write_file(handle, "/tmp/.gemini/settings.json", payload)
    :ok
  end

  # Make sure the workspace exists and is a git repo; gemini's
  # MemoryDiscovery is happy as long as it finds *some* .git when it
  # walks up from cwd.
  @impl true
  def prepare_sandbox(handle, _agent, sprite_env) do
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

    # The session-store workaround travels with the workspace (#659): it has to
    # be on disk before the first turn ends, since that is when it first runs.
    _ = Fountain.Runtimes.Gemini.SessionStore.install(handle)

    case Fountain.Sandbox.exec(handle, "bash", ["-lc", script],
           env: sprite_env,
           timeout: 30_000
         ) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, code} -> {:error, {:gemini_workspace_init_exit, code}}
      {:error, reason} -> {:error, {:gemini_workspace_init, reason}}
    end
  end
end
