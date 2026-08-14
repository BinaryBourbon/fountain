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

      # The name already exists — adopt it, exactly like the 409 rule on
      # Sprites. Daytona's conflict shape is verified permissive here: any
      # 4xx where a subsequent get succeeds is an adoption.
      {:error, {:api_error, status, _body}} when status in [400, 409] ->
        case Api.get_sandbox(name) do
          {:ok, _info} -> {:ok, build_handle(name)}
          {:error, reason} -> {:error, Errors.normalize(reason)}
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
    with {:ok, _url} <- ensure_started(name) do
      {:ok, handle}
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

  @impl true
  def spawn(%Handle{name: name}, cmd, args, opts) do
    with {:ok, url} <- ensure_started(name) do
      tag = "fountain-#{System.unique_integer([:positive])}"
      ref = make_ref()
      owner = Keyword.get(opts, :owner, self())
      command = render_command(cmd, args, opts)

      with :ok <- Toolbox.create_session(url, tag) |> normalize_ok(),
           {:ok, command_id} <- exec_async(url, tag, command),
           {:ok, pid} <-
             LogStream.start(
               toolbox_url: url,
               session_id: tag,
               command_id: command_id,
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
    case Toolbox.send_input(private.toolbox_url, private.session_id, private.command_id, data) do
      :ok ->
        :ok

      # The daemon refuses input to a finished command; that is the #603
      # shape, not a transport problem.
      {:error, {:api_error, status, _body}} when status in [400, 404, 409, 410] ->
        {:error, :command_exited}

      {:error, reason} ->
        {:error, {:write_failed, Errors.normalize(reason)}}
    end
  end

  # Daytona's FIFO has no EOF operation. The ACP path never needs a mid-turn
  # EOF (stdin deliberately stays open), and one-shot stdin consumers go
  # through exec/4 with a pipe instead.
  @impl true
  def close_stdin(%Command{provider: :daytona}), do: :ok

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
