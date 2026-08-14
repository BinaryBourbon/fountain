defmodule Fountain.Sandbox.Daytona do
  @moduledoc """
  The Daytona adapter: `Fountain.Sandbox` implemented against daytona.io
  (or a self-hosted Daytona via `DAYTONA_API_URL`).

  Daytona is the closest semantic match to the contract of any provider:

    * sandboxes are genuinely **name-addressable** — the minted name goes
      straight into API paths, no metadata emulation;
    * the daemon **journals command output server-side and the log stream
      replays it from byte zero before following** — the replay-from-start
      contract holds natively, with no shim;
    * `stop`/`start` preserve the whole disk, so `:suspend` is real; a
      long-parked sandbox auto-archives to object storage (still startable,
      just slower) so it stops consuming disk quota;
    * `ttlMinutes: 0` and `autoStopInterval: 0` at create — no TTL
      treadmill; Fountain's own lifecycle owns suspension.

  Streaming commands are daemon-side *sessions*: `spawn/4` creates a
  session named by the command tag, execs asynchronously, and a
  `Fountain.Sandbox.Daytona.LogStream` WebSocket translates the journaled
  log into owner frames. `attach/3` is the same stream opened again — the
  journal replays from the start. Stdin is the daemon's per-command FIFO:
  line-oriented (a trailing newline is appended when missing), which suits
  the NDJSON JSON-RPC the ACP path writes; there is **no stdin EOF
  operation**, so `close_stdin/1` is a documented no-op — the paths that
  need an ending signal (codex's one-shot login) pipe via `exec/4` instead.

  Sandboxes are created from `DAYTONA_SNAPSHOT`, which must carry the
  agent CLIs and the `sprite` user layout the provisioning pipeline
  assumes — see `images/daytona/` for the reference Dockerfile.
  """

  @behaviour Fountain.Sandbox

  alias Fountain.Sandbox.Command
  alias Fountain.Sandbox.Daytona.Api
  alias Fountain.Sandbox.Daytona.Errors
  alias Fountain.Sandbox.Daytona.LogStream
  alias Fountain.Sandbox.Daytona.Toolbox
  alias Fountain.Sandbox.Handle
  alias Fountain.Sandbox.NetworkPolicy
  alias Fountain.Sandbox.Session

  @impl true
  def provider, do: :daytona

  @impl true
  def capabilities, do: MapSet.new([:suspend, :network_policy, :attach])

  @impl true
  def build_handle(name) when is_binary(name), do: %Handle{provider: :daytona, name: name}

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @impl true
  def create(name, _opts) when is_binary(name) do
    case Api.create_sandbox(name) do
      {:ok, _info} ->
        {:ok, build_handle(name)}

      # A 4xx where a follow-up get finds the sandbox is a name conflict —
      # adopt it, exactly like the 409 rule on Sprites. When the get finds
      # nothing, the create failed for a real reason (e.g. an unregistered
      # snapshot answers 400) and THAT error must surface, not the probe's
      # not-found.
      {:error, {:api_error, status, _body} = create_error} when status in [400, 409] ->
        case Api.get_sandbox(name) do
          {:ok, _info} -> {:ok, build_handle(name)}
          {:error, _probe_miss} -> {:error, Errors.normalize(create_error)}
        end

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def get(%Handle{name: name}) do
    case Api.get_sandbox(name) do
      {:ok, info} -> {:ok, %{status: normalize_state(info), raw: info}}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def destroy(%Handle{name: name}) do
    Api.delete_sandbox(name) |> normalize_ok()
  end

  @impl true
  def list_all_names do
    case Api.list_all_names() do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def suspend(%Handle{name: name}) do
    case Api.get_sandbox(name) do
      {:ok, %{"state" => state}} when state in ["stopped", "stopping", "archived"] -> :ok
      {:ok, _info} -> Api.stop(name) |> normalize_ok()
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def resume(%Handle{name: name} = handle) do
    case ensure_started(name) do
      {:ok, _url} ->
        {:ok, handle}

      # `start` answers 409 while the sandbox is still mid-transition
      # (`stopping`/`archiving`); that is weather, not a verdict — the wake
      # path retries transient errors.
      {:error, {:invalid, {:http, 409, body}}} ->
        {:error, {:unavailable, {:http, 409, body}}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── filesystem ─────────────────────────────────────────────────────────────

  @impl true
  def write_file(%Handle{name: name}, path, data, _opts) do
    with {:ok, url} <- ensure_started(name) do
      Toolbox.write_file(url, path, data) |> normalize_ok()
    end
  end

  # ── exec ───────────────────────────────────────────────────────────────────

  @impl true
  def exec(%Handle{name: name}, cmd, args, opts) do
    with {:ok, url} <- ensure_started(name) do
      command = render_command(cmd, args, opts)

      case Toolbox.execute(url, command, opts) do
        {:ok, output, code} -> {:ok, output, code}
        {:error, reason} -> {:error, Errors.normalize(reason)}
      end
    end
  end

  # Session exec runs inside the session's shell, so env and cwd ride in the
  # command string. stderr separation comes from the journal's own
  # multiplexing, not the shell.
  defp render_command(cmd, args, opts) do
    quoted = Enum.map_join([cmd | args], " ", &shell_quote/1)

    prefix =
      opts
      |> Keyword.get(:env, [])
      |> Enum.map_join(" ", fn {k, v} -> "#{k}=#{shell_quote(to_string(v))}" end)

    cd =
      case Keyword.get(opts, :dir) do
        nil -> ""
        dir -> "cd #{shell_quote(dir)} && "
      end

    String.trim("#{cd}#{prefix} #{quoted}")
  end

  defp shell_quote(s), do: "'" <> String.replace(to_string(s), "'", "'\\''") <> "'"

  # Daytona's per-command stdin FIFO delivers EOF after every input POST —
  # measured live: one write ended a `while read` loop — so a command that
  # needs a long-lived stdin (the ACP turn) reads from a `tail -f`-fed file
  # instead. Writes append to the file via one-shot execs; killing the tail
  # is a REAL stdin EOF. The tail orphaned by a command that exits on its
  # own lingers idle until the sandbox stops — harmless, and the price of
  # a working stdin.
  # POSIX sh only — session commands do not run under bash, so no process
  # substitution: the tail feeds a private FIFO the command reads as stdin,
  # and killing the tail (close_stdin) EOFs it. The daemon's command record
  # carries no exit code (measured live), so the shim writes it to a
  # sentinel file the LogStream polls — the same pattern as the E2B
  # journaling shim.
  defp stdin_shim(tag, command) do
    base = "/tmp/fountain/#{tag}"

    """
    mkdir -p /tmp/fountain
    rm -f #{base}.p #{base}.code
    mkfifo #{base}.p
    : > #{base}.in
    tail -c +1 -f #{base}.in > #{base}.p &
    FOUNTAIN_TAIL=$!
    echo $FOUNTAIN_TAIL > #{base}.tailpid
    #{command} < #{base}.p
    FOUNTAIN_CODE=$?
    kill $FOUNTAIN_TAIL 2>/dev/null
    echo $FOUNTAIN_CODE > #{base}.code
    exit $FOUNTAIN_CODE
    """
  end

  defp plain_shim(tag, command) do
    base = "/tmp/fountain/#{tag}"

    """
    mkdir -p /tmp/fountain
    rm -f #{base}.code
    #{command}
    FOUNTAIN_CODE=$?
    echo $FOUNTAIN_CODE > #{base}.code
    exit $FOUNTAIN_CODE
    """
  end

  defp exit_file(session_id), do: "/tmp/fountain/#{session_id}.code"

  @impl true
  def spawn(%Handle{name: name}, cmd, args, opts) do
    with {:ok, url} <- ensure_started(name) do
      tag = "fountain-#{System.unique_integer([:positive])}"
      ref = make_ref()
      owner = Keyword.get(opts, :owner, self())
      rendered = render_command(cmd, args, opts)

      command =
        if Keyword.get(opts, :stdin, false),
          do: stdin_shim(tag, rendered),
          else: plain_shim(tag, rendered)

      with :ok <- Toolbox.create_session(url, tag) |> normalize_ok(),
           {:ok, command_id} <- exec_async(url, tag, command),
           {:ok, pid} <-
             LogStream.start(
               toolbox_url: url,
               session_id: tag,
               command_id: command_id,
               exit_file: exit_file(tag),
               ref: ref,
               owner: owner
             ) do
        {:ok,
         %Command{
           provider: :daytona,
           ref: ref,
           private: %{pid: pid, toolbox_url: url, session_id: tag, command_id: command_id}
         }}
      end
    end
  end

  defp exec_async(url, tag, command) do
    case Toolbox.exec_async(url, tag, command) do
      {:ok, command_id} -> {:ok, command_id}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def write_stdin(%Command{provider: :daytona, private: private}, data) do
    # One round-trip that appends only while the command lives: the shim's
    # exit sentinel is the daemon-independent word on liveness (the command
    # record carries no exit code), and writing after exit must be the #603
    # error, not a silent append nobody reads.
    encoded = Base.encode64(IO.iodata_to_binary(data))
    base = "/tmp/fountain/#{private.session_id}"

    command =
      "if [ -f #{base}.code ]; then echo FOUNTAIN_EXITED; " <>
        "else printf %s '#{encoded}' | base64 -d >> #{base}.in; fi"

    case Toolbox.execute(private.toolbox_url, command, timeout: 30_000) do
      {:ok, out, 0} ->
        if String.contains?(out, "FOUNTAIN_EXITED"), do: {:error, :command_exited}, else: :ok

      {:ok, out, code} ->
        {:error, {:write_failed, {:stdin_append_exit, code, out}}}

      {:error, reason} ->
        {:error, {:write_failed, Errors.normalize(reason)}}
    end
  end

  # Killing the tail that feeds the stdin file closes the command's stdin —
  # a real EOF, unlike the daemon FIFO (which has no close operation). The
  # tail's pid was written by the shim; `kill` is a builtin, so this works
  # on images without procps.
  @impl true
  def close_stdin(%Command{provider: :daytona, private: private}) do
    base = "/tmp/fountain/#{private.session_id}"
    command = "kill $(cat #{base}.tailpid) 2>/dev/null; true"

    case Toolbox.execute(private.toolbox_url, command, timeout: 30_000) do
      {:ok, _out, _code} -> :ok
      {:error, _reason} -> :ok
    end
  end

  @impl true
  def stop_command(%Command{provider: :daytona, private: %{pid: pid}}) do
    GenServer.stop(pid, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  # ── sessions ───────────────────────────────────────────────────────────────

  @impl true
  def list_sessions(%Handle{name: name}) do
    with {:ok, url} <- ensure_started(name) do
      case Toolbox.list_sessions(url) do
        {:ok, sessions} ->
          normalized =
            for %{"sessionId" => id} = session <- sessions,
                is_binary(id) and String.starts_with?(id, "fountain-") do
              %Session{id: id, command: newest_command(session)}
            end

          {:ok, normalized}

        {:error, reason} ->
          {:error, Errors.normalize(reason)}
      end
    end
  end

  @impl true
  def attach(%Handle{name: name}, session_id, opts) do
    with {:ok, url} <- ensure_started(name) do
      ref = make_ref()
      owner = Keyword.get(opts, :owner, self())

      with {:ok, command_id} <- newest_command_id(url, session_id),
           {:ok, pid} <-
             LogStream.start(
               toolbox_url: url,
               session_id: session_id,
               command_id: command_id,
               exit_file: exit_file(session_id),
               ref: ref,
               owner: owner
             ) do
        {:ok,
         %Command{
           provider: :daytona,
           ref: ref,
           private: %{pid: pid, toolbox_url: url, session_id: session_id, command_id: command_id}
         }}
      end
    end
  end

  defp newest_command_id(url, session_id) do
    case Toolbox.list_sessions(url) do
      {:ok, sessions} ->
        case Enum.find(sessions, &(&1["sessionId"] == session_id)) do
          nil ->
            {:error, :not_found}

          session ->
            case session |> commands() |> List.last() do
              %{"id" => id} -> {:ok, id}
              %{"cmdId" => id} -> {:ok, id}
              _ -> {:error, :not_found}
            end
        end

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  defp commands(%{"commands" => commands}) when is_list(commands), do: commands
  defp commands(_session), do: []

  defp newest_command(session) do
    case session |> commands() |> List.last() do
      %{"command" => command} when is_binary(command) -> command
      _ -> nil
    end
  end

  # ── governance ─────────────────────────────────────────────────────────────

  @impl true
  def apply_network_policy(%Handle{name: name}, %NetworkPolicy{allow: allow}) do
    Api.set_network(name, allow) |> normalize_ok()
  end

  @impl true
  def create_checkpoint(%Handle{}, _opts), do: {:error, :not_supported}

  @impl true
  def restore_checkpoint(%Handle{}, _checkpoint_id), do: {:error, :not_supported}

  # ── internals ──────────────────────────────────────────────────────────────

  # Resolve the toolbox URL, starting a stopped sandbox on the way: a parked
  # (or archived) sandbox under a `ready` row self-heals on the next use,
  # the same rule as the E2B adapter's auto-resume.
  defp ensure_started(name) do
    case Api.get_sandbox(name) do
      {:ok, %{"state" => state}} when state in ["stopped", "stopping", "archived", "archiving"] ->
        case Api.start(name) do
          :ok -> toolbox(name)
          {:error, reason} -> {:error, Errors.normalize(reason)}
        end

      {:ok, _info} ->
        toolbox(name)

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  defp toolbox(name) do
    case Api.toolbox_url(name) do
      {:ok, url} -> {:ok, url}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  defp normalize_state(%{"state" => state}) when state in ["started", "starting", "resuming"],
    do: :running

  defp normalize_state(%{"state" => state})
       when state in ["stopped", "stopping", "archived", "archiving", "paused", "pausing"],
       do: :suspended

  defp normalize_state(_info), do: :unknown

  defp normalize_ok(:ok), do: :ok
  defp normalize_ok({:error, reason}), do: {:error, Errors.normalize(reason)}
end
