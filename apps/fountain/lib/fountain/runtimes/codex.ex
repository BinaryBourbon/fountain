defmodule Fountain.Runtimes.Codex do
  @moduledoc """
  OpenAI Codex CLI runtime.

  Argv shape:

      mode == :run       → codex exec
                              --dangerously-bypass-approvals-and-sandbox
                              --json --model <model_id> <PROMPT>
      mode == :continue  → codex exec resume --last
                              --dangerously-bypass-approvals-and-sandbox
                              --json --model <model_id> <PROMPT>

  `--model` (also spelled `-m`) takes the bare id, so the canonical
  `openai/` prefix on `agent.model` is stripped — see
  `Fountain.Runtimes.Model`.

  The prompt is passed as the **trailing positional argument** rather
  than on stdin. When codex sees a piped stdin it logs an ugly
  `"Reading prompt from stdin..."` line to stderr; passing the prompt
  in argv side-steps that. We return `stdin?: false` from build_command
  so conversation_server skips the write/close_stdin dance.

  Codex tracks its own per-workspace conversation state on disk, so we
  pass no session id; `--last` (in `continue` mode) tells it to reattach
  to the most recent conversation in the workspace. `--json` is the
  line-delimited stream-json output the worker tails into LogEvents.

  Auth: `OPENAI_API_KEY` is consumed once at provision time via
  `prepare_sprite/3` (see below).
  """

  @behaviour Fountain.Runtimes

  alias Fountain.Runtimes.Model

  @impl true
  def skills_root, do: "/home/sprite/.codex/skills"

  @impl true
  def skills_sh_agent, do: "codex"

  @impl true
  def build_command(agent, prompt, mode, _runtime_session_id, opts) do
    base =
      if mode == :continue do
        [
          "exec",
          "resume",
          "--last",
          "--dangerously-bypass-approvals-and-sandbox",
          "--json",
          "--color",
          "never"
        ]
      else
        [
          "exec",
          "--dangerously-bypass-approvals-and-sandbox",
          "--json",
          "--color",
          "never"
        ]
      end

    # codex exec natively supports --image <path> for multimodal input.
    image_args =
      opts
      |> Keyword.get(:images, [])
      |> Enum.flat_map(fn {path, _mt} -> ["--image", path] end)

    # codex prints an "additional input from stdin" / "prompt from
    # stdin" warning whenever `isatty(0)` is false. Both a piped stdin
    # AND a /dev/null redirect trigger it. Allocate a PTY (`tty?: true`)
    # so codex sees stdin as a TTY and stays quiet. We pass the prompt
    # as argv so codex doesn't actually read from the PTY.
    {"codex", base ++ Model.model_args(agent) ++ image_args ++ [prompt],
     stdin?: false, tty?: true}
  end

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
  def prepare_sprite(sprite, _agent, sprite_env) do
    case List.keyfind(sprite_env, "OPENAI_API_KEY", 0) do
      {"OPENAI_API_KEY", key} when is_binary(key) and key != "" ->
        case Sprites.spawn(sprite, "codex", ["login", "--with-api-key"],
               owner: self(),
               stdin: true,
               env: sprite_env
             ) do
          {:ok, command} ->
            # Same exposure as #603: `codex login` exiting before it reads the
            # key — a missing binary, a bad flag — would otherwise exit whoever
            # is provisioning, rather than returning an error they can report.
            case Fountain.SpriteStdin.write(command, key <> "\n") do
              :ok ->
                :ok = Sprites.close_stdin(command)

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
