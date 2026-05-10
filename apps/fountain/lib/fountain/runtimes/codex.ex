defmodule Fountain.Runtimes.Codex do
  @moduledoc """
  OpenAI Codex CLI runtime.

  Argv shape:

      mode == :run       → codex exec
                              --dangerously-bypass-approvals-and-sandbox
                              --json <PROMPT>
      mode == :continue  → codex exec resume --last
                              --dangerously-bypass-approvals-and-sandbox
                              --json <PROMPT>

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

  @impl true
  def skills_root, do: "/home/sprite/.codex/skills"

  @impl true
  def skills_sh_agent, do: "codex"

  @impl true
  def build_command(_agent, prompt, mode, _runtime_session_id, opts) do
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
    {"codex", base ++ image_args ++ [prompt], stdin?: false, tty?: true}
  end

  @impl true
  def default_env(_agent, inference_credentials) do
    case Map.get(inference_credentials, :openai_api_key) do
      nil -> []
      "" -> []
      key -> [{"OPENAI_API_KEY", key}]
    end
  end

  # Codex reads `~/.codex/config.toml`; MCP servers go under
  # `[mcp_servers.<name>]` (snake_case, NOT `mcpServers`).
  @impl true
  def write_config(_sprite, nil), do: :ok
  def write_config(_sprite, %{mcp_servers: m}) when m == %{} or is_nil(m), do: :ok

  def write_config(sprite, %{mcp_servers: mcp_servers}) do
    fs = Sprites.filesystem(sprite, "/")
    Sprites.Filesystem.mkdir_p(fs, "/home/sprite/.codex")
    Sprites.Filesystem.write(fs, "/home/sprite/.codex/config.toml", render_toml(mcp_servers))
    :ok
  end

  defp render_toml(mcp_servers) do
    mcp_servers
    |> Enum.sort()
    |> Enum.map_join("\n", &render_server/1)
  end

  defp render_server({name, %{} = entry}) do
    fields =
      [
        toml_kv("command", Map.get(entry, "command")),
        toml_array("args", Map.get(entry, "args", [])),
        toml_inline_table("env", Map.get(entry, "env", %{}))
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    "[mcp_servers.#{name}]\n#{fields}\n"
  end

  defp toml_kv(_, nil), do: nil
  defp toml_kv(k, v) when is_binary(v), do: ~s(#{k} = "#{toml_escape(v)}")

  defp toml_array(_, []), do: nil

  defp toml_array(k, list) when is_list(list) do
    items = Enum.map_join(list, ", ", &~s("#{toml_escape(to_string(&1))}"))
    "#{k} = [#{items}]"
  end

  defp toml_inline_table(_, m) when m == %{}, do: nil

  defp toml_inline_table(k, m) when is_map(m) do
    pairs = Enum.map_join(m, ", ", fn {ek, ev} -> ~s(#{ek} = "#{toml_escape(to_string(ev))}") end)
    "#{k} = { #{pairs} }"
  end

  defp toml_escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"  ))
  end

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
            :ok = Sprites.write(command, key <> "\n")
            :ok = Sprites.close_stdin(command)

            receive do
              {:exit, %{ref: ref}, 0} when ref == command.ref ->
                :ok

              {:exit, %{ref: ref}, code} when ref == command.ref ->
                {:error, {:codex_login_exit, code}}
            after
              30_000 -> {:error, :codex_login_timeout}
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
