defmodule Managoat.Runtimes.Codex do
  @moduledoc """
  OpenAI Codex runtime — provisioning only.

  Turns speak ACP through the pinned `codex-acp` adapter
  (`Managoat.Runtimes.ACP`); the `codex exec` argv builder — and with it the
  resume-by-guessing `--last` flag, the worst thing this module shipped —
  went with the legacy spawn path. What remains is the half ADR 0014
  deliberately kept: credentials and skills.

  Auth: `OPENAI_API_KEY` is consumed once at provision time via
  `prepare_sandbox/3` (see below) — codex reads `~/.codex/auth.json`, not the
  process env, and the adapter runs on the same store.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout

  @runtime "codex"

  @impl true
  def skills_root, do: Layout.skills_root(@runtime)

  @impl true
  def skills_sh_agent, do: Layout.skills_sh_agent(@runtime)

  @impl true
  def default_env(_agent, inference_credentials) do
    case Map.get(inference_credentials, :openai_api_key) do
      nil -> []
      "" -> []
      key -> [{"OPENAI_API_KEY", key}]
    end
  end

  # MCP servers travel in `session/new`'s `mcpServers` param on the ACP path
  # (#636); the `~/.codex/config.toml` writer that used to live here served
  # the bare CLI. An agent opted out of ACP runs its legacy turns without MCP
  # servers.

  # codex 0.118+ does NOT read OPENAI_API_KEY at exec time — it only reads
  # `~/.codex/auth.json`, which `codex login --with-api-key` writes by
  # consuming the key on stdin. Run the login once at provision time.
  @impl true
  def prepare_sandbox(handle, _agent, sprite_env) do
    case List.keyfind(sprite_env, "OPENAI_API_KEY", 0) do
      {"OPENAI_API_KEY", key} when is_binary(key) and key != "" ->
        case Managoat.Sandbox.spawn(handle, "codex", ["login", "--with-api-key"],
               owner: self(),
               stdin: true,
               env: sprite_env
             ) do
          {:ok, command} ->
            # Same exposure as #603: `codex login` exiting before it reads the
            # key — a missing binary, a bad flag — would otherwise exit whoever
            # is provisioning, rather than returning an error they can report.
            # write_stdin/2 is total by contract, so that exposure stays closed.
            case Managoat.Sandbox.write_stdin(command, key <> "\n") do
              :ok ->
                Managoat.Sandbox.close_stdin(command)

                receive do
                  {:exit, %{ref: ref}, 0} when ref == command.ref ->
                    :ok

                  {:exit, %{ref: ref}, code} when ref == command.ref ->
                    {:error, {:codex_login_exit, code}}
                after
                  30_000 -> {:error, :codex_login_timeout}
                end

              {:error, reason} ->
                {:error, {:codex_login_write, reason}}
            end

          err ->
            {:error, {:codex_login_spawn, err}}
        end

      _ ->
        # No key in env — surface that explicitly; without it the
        # subsequent `codex exec` will 401 with a confusing message.
        {:error, :missing_openai_api_key}
    end
  end
end
