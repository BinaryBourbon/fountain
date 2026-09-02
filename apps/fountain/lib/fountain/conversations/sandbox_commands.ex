defmodule Fountain.Conversations.SandboxCommands do
  @moduledoc """
  A command run, or a file read, on a sandbox the caller owns — the seam
  behind `POST /api/sandboxes/:id/exec` and `GET /api/sandboxes/:id/files`.

  Both go through `Managoat.Sandbox.exec/4`, the same call provisioning makes
  for a package install or a clone, so every backend that can provision can
  answer. They are for a client that wants to *look* at a machine it is
  paying for — `git diff` in a review panel, a file beside a comment — and
  three rules keep them that:

    * **The sandbox must be `ready`.** A parked machine is not woken here; a
      wake is what a prompt does, and the caller's next prompt will do it.
      Anything else is `{:error, {:sandbox_not_ready, status}}`.
    * **A running turn does not block a call.** The point is to read the
      tree *while* the agent works; a caller that runs something destructive
      mid-turn has the same power it always had through a prompt. The API
      docs say so.
    * **Output is capped, and the audit row holds sizes, never content**
      (ADR 0013): the command line and the bytes are tenant data that would
      otherwise sit in a second, less guarded place.

  Only a full-scope key reaches the routes (the router's
  `:require_full_scope`): a sandbox's own per-conversation token running
  commands on other sandboxes of the account would be a lateral move.
  """

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox

  @default_timeout_ms 60_000
  @max_timeout_ms 600_000
  @output_cap 1_000_000
  @file_cap 4_000_000

  @doc "The exec output cap in bytes; more is cut and `truncated` says so."
  def output_cap, do: @output_cap

  @doc "The file read cap in bytes."
  def file_cap, do: @file_cap

  @doc "The default and largest exec timeouts, in ms."
  def timeouts, do: {@default_timeout_ms, @max_timeout_ms}

  @type exec_result :: %{
          output: binary(),
          exit_code: integer(),
          duration_ms: non_neg_integer(),
          truncated: boolean()
        }

  @doc """
  Run `command` with `args` on the sandbox and wait for it. Options: `:cwd`,
  `:timeout_ms` (default #{@default_timeout_ms}, at most #{@max_timeout_ms}),
  plus the audit attribution (`:actor`, `:request_ip`).

  stderr is interleaved into `output`: the sandbox seam returns one stream,
  and a diff tool's reader wants them in order anyway.
  """
  @spec exec(Sandbox.t(), String.t(), [String.t()], keyword()) ::
          {:ok, exec_result()} | {:error, term()}
  def exec(%Sandbox{} = sandbox, command, args, opts \\ [])
      when is_binary(command) and is_list(args) do
    timeout = opts |> Keyword.get(:timeout_ms, @default_timeout_ms) |> clamp_timeout()

    exec_opts =
      [stderr_to_stdout: true, timeout: timeout] ++
        case Keyword.get(opts, :cwd) do
          nil -> []
          dir -> [dir: dir]
        end

    with :ok <- ready(sandbox),
         {:ok, output, code, duration} <- run(sandbox, command, args, exec_opts) do
      {output, truncated} = cap(output, @output_cap)

      audit("sandbox.exec", sandbox, opts, %{
        "args" => length(args),
        "exit_code" => code,
        "output_bytes" => byte_size(output),
        "truncated" => truncated,
        "duration_ms" => duration
      })

      {:ok, %{output: output, exit_code: code, duration_ms: duration, truncated: truncated}}
    end
  end

  # Exit codes the read script uses to say why there is no file. Chosen high
  # so a `cat` failure (1) or a signal is never mistaken for one of them.
  @no_such 44
  @not_a_file 45

  @doc """
  Read one file's bytes. `{:error, :file_not_found}` when nothing is at the
  path, `{:error, :not_a_file}` for a directory or an unreadable entry. The
  read is `head -c` past the cap so the caller learns it was cut.
  """
  @spec read_file(Sandbox.t(), String.t(), keyword()) ::
          {:ok, binary(), truncated :: boolean()} | {:error, term()}
  def read_file(%Sandbox{} = sandbox, path, opts \\ []) when is_binary(path) do
    script =
      ~s(if [ ! -e "$1" ]; then exit #{@no_such}; fi; ) <>
        ~s(if [ ! -f "$1" ] || [ ! -r "$1" ]; then exit #{@not_a_file}; fi; ) <>
        ~s(exec head -c #{@file_cap + 1} -- "$1")

    with :ok <- ready(sandbox),
         {:ok, output, code, duration} <-
           run(sandbox, "sh", ["-c", script, "sh", path],
             stderr_to_stdout: false,
             timeout: 60_000
           ) do
      case code do
        0 ->
          {bytes, truncated} = cap(output, @file_cap)

          audit("sandbox.file_read", sandbox, opts, %{
            "bytes" => byte_size(bytes),
            "truncated" => truncated,
            "duration_ms" => duration
          })

          {:ok, bytes, truncated}

        @no_such ->
          {:error, :file_not_found}

        @not_a_file ->
          {:error, :not_a_file}

        other ->
          {:error, {:sandbox_exec_failed, {:exit, other}}}
      end
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────

  defp ready(%Sandbox{status: "ready"}), do: :ok
  defp ready(%Sandbox{status: status}), do: {:error, {:sandbox_not_ready, status}}

  defp run(sandbox, command, args, exec_opts) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.sprite_name
      )

    started = System.monotonic_time(:millisecond)

    case Managoat.Sandbox.exec(handle, command, args, exec_opts) do
      {:ok, output, code} when is_binary(output) and is_integer(code) ->
        {:ok, output, code, System.monotonic_time(:millisecond) - started}

      {:error, {:unavailable, {:exec_timeout, _}}} ->
        {:error, :exec_timeout}

      {:error, reason} ->
        {:error, {:sandbox_exec_failed, reason}}
    end
  end

  defp clamp_timeout(ms) when is_integer(ms) and ms > 0, do: min(ms, @max_timeout_ms)
  defp clamp_timeout(_), do: @default_timeout_ms

  defp cap(bytes, limit) when byte_size(bytes) > limit, do: {binary_part(bytes, 0, limit), true}
  defp cap(bytes, _limit), do: {bytes, false}

  defp audit(action, sandbox, opts, metadata) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.put(metadata, "provider", sandbox.provider)
    })
  end
end
