defmodule Managoat.Runner.Adapter do
  @moduledoc """
  The self-hosted runner adapter: `Managoat.Sandbox` implemented as RPCs to a
  runner daemon on a machine the user owns.

  Everything runner-shaped lives here and in `Managoat.Runner.Connection`:
  the name → runner-id routing (`runner-<32 hex>-<8 hex>`, see
  `Managoat.Runner.Names`), the request vocabulary, and the
  offline/disconnected/timeout errors, all of which are `{:unavailable, _}` —
  transient in the taxonomy, so a wake retries and a parked directory on a
  switched-off machine is never mistaken for `:not_found`.

  Capability notes:

    * `:suspend` is advertised — a suspended sandbox is a directory whose
      processes were stopped, which costs nothing and preserves the disk;
      `resume/1` is a no-op probe;
    * `:attach` is advertised — the daemon journals every session and
      replays from byte zero;
    * `:network_policy` is **not** — the machine is the user's and so is its
      network; `apply_network_policy/2` refuses rather than pretending.
  """

  @behaviour Managoat.Sandbox

  alias Managoat.Runner.Config
  alias Managoat.Runner.Connection
  alias Managoat.Runner.Names
  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy
  alias Managoat.Sandbox.Session

  @impl true
  def provider, do: :runner

  @impl true
  def capabilities, do: MapSet.new([:suspend, :attach])

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @impl true
  def build_handle(name) when is_binary(name), do: %Handle{provider: :runner, name: name}

  @impl true
  def create(name, _opts) when is_binary(name) do
    with {:ok, _} <- rpc(name, %{op: "create"}) do
      {:ok, build_handle(name)}
    end
  end

  @impl true
  def get(%Handle{name: name}) do
    with {:ok, result} <- rpc(name, %{op: "get"}) do
      {:ok, %{status: status(result), raw: result}}
    end
  end

  defp status(%{"status" => "suspended"}), do: :suspended
  defp status(%{"status" => "running"}), do: :running
  defp status(_), do: :unknown

  @impl true
  def destroy(%Handle{name: name}) do
    case rpc(name, %{op: "destroy"}) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def list_all_names do
    # The view is "every online runner, right now". An offline runner's
    # sandboxes are simply not listed, which the reaper treats as skip — it
    # only ever destroys names it *sees*. One online runner refusing to list
    # refuses the whole view: a partial listing that looks whole is the worst
    # shape of wrong for a function that decides what to delete.
    Config.host!().online()
    |> Enum.reduce_while({:ok, MapSet.new()}, fn {runner_id, _meta}, {:ok, acc} ->
      case Connection.call(runner_id, %{op: "list"}) do
        {:ok, %{"names" => names}} when is_list(names) ->
          {:cont, {:ok, MapSet.union(acc, MapSet.new(names))}}

        {:ok, other} ->
          {:halt, {:error, {:provider, :runner, {:malformed_list, other}}}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  @impl true
  def suspend(%Handle{name: name}) do
    with {:ok, _} <- rpc(name, %{op: "suspend"}), do: :ok
  end

  @impl true
  def resume(%Handle{name: name} = handle) do
    with {:ok, _} <- rpc(name, %{op: "resume"}), do: {:ok, handle}
  end

  @impl true
  def public_url(%Handle{}), do: {:error, :unsupported}

  # ── filesystem ─────────────────────────────────────────────────────────────

  @impl true
  def write_file(%Handle{name: name}, path, data, opts) do
    payload = %{
      op: "write_file",
      path: path,
      data: Base.encode64(IO.iodata_to_binary(data)),
      mode: Keyword.get(opts, :mode)
    }

    with {:ok, _} <- rpc(name, payload), do: :ok
  end

  # ── exec ───────────────────────────────────────────────────────────────────

  @impl true
  def exec(%Handle{name: name}, cmd, args, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)

    payload = %{
      op: "exec",
      cmd: cmd,
      args: args,
      env: env_pairs(opts),
      dir: Keyword.get(opts, :dir),
      timeout_ms: if(timeout == :infinity, do: nil, else: timeout),
      stderr_to_stdout: Keyword.get(opts, :stderr_to_stdout, false)
    }

    call_timeout = if timeout == :infinity, do: :infinity, else: timeout + 10_000

    case rpc(name, payload, timeout: call_timeout) do
      {:ok, %{"output" => b64, "code" => code}} when is_integer(code) ->
        {:ok, decode(b64), code}

      {:ok, other} ->
        {:error, {:provider, :runner, {:malformed_exec_reply, other}}}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def spawn(%Handle{name: name}, cmd, args, opts) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    payload = %{
      op: "spawn",
      cmd: cmd,
      args: args,
      env: env_pairs(opts),
      dir: Keyword.get(opts, :dir),
      stdin: Keyword.get(opts, :stdin, false),
      tty: Keyword.get(opts, :tty, false),
      detachable: Keyword.get(opts, :detachable, false)
    }

    with {:ok, runner_id} <- runner_id(name),
         {:ok, %{"session_id" => session_id}} <-
           Connection.call(runner_id, Map.put(payload, :name, name), subscribe: {owner, ref}) do
      {:ok, command(runner_id, name, session_id, ref)}
    else
      {:ok, other} -> {:error, {:provider, :runner, {:malformed_spawn_reply, other}}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def write_stdin(%Command{provider: :runner, private: private}, data) do
    payload = %{
      op: "stdin",
      name: private.name,
      session_id: private.session_id,
      data: Base.encode64(IO.iodata_to_binary(data))
    }

    case Connection.call(private.runner_id, payload) do
      {:ok, _} -> :ok
      {:error, :command_exited} -> {:error, :command_exited}
      {:error, :not_found} -> {:error, :command_exited}
      {:error, {:unavailable, why}} -> {:error, {:write_failed, why}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def close_stdin(%Command{provider: :runner, private: private}) do
    payload = %{op: "stdin_close", name: private.name, session_id: private.session_id}

    case Connection.call(private.runner_id, payload) do
      {:ok, _} -> :ok
      {:error, :not_found} -> :ok
      {:error, :command_exited} -> :ok
      {:error, _} = err -> err
    end
  end

  @impl true
  def stop_command(%Command{provider: :runner, ref: ref, private: private}) do
    # This end only: stop listening; the connection tells the daemon to stop
    # streaming once nobody here listens. The process keeps running (that is
    # what reattach exists for). Total by construction — an offline runner has
    # nothing to stop.
    Connection.unsubscribe(private.runner_id, private.session_id, ref)
  end

  # ── sessions ───────────────────────────────────────────────────────────────

  @impl true
  def list_sessions(%Handle{name: name}) do
    with {:ok, %{"sessions" => sessions}} when is_list(sessions) <-
           rpc(name, %{op: "list_sessions"}) do
      {:ok, Enum.map(sessions, &to_session/1)}
    else
      {:ok, other} -> {:error, {:provider, :runner, {:malformed_sessions_reply, other}}}
      {:error, _} = err -> err
    end
  end

  defp to_session(%{"id" => id} = s) do
    %Session{
      id: id,
      command: Map.get(s, "command"),
      created_at: parse_time(Map.get(s, "created_at")),
      last_activity_at: parse_time(Map.get(s, "last_activity_at")),
      tty: Map.get(s, "tty", false)
    }
  end

  defp parse_time(nil), do: nil

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  @impl true
  def attach(%Handle{name: name}, session_id, opts) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    with {:ok, runner_id} <- runner_id(name),
         {:ok, %{"session_id" => ^session_id}} <-
           Connection.call(
             runner_id,
             %{
               op: "attach",
               name: name,
               session_id: session_id,
               stdin: Keyword.get(opts, :stdin, false)
             },
             subscribe: {owner, ref}
           ) do
      {:ok, command(runner_id, name, session_id, ref)}
    else
      {:ok, other} -> {:error, {:provider, :runner, {:malformed_attach_reply, other}}}
      {:error, _} = err -> err
    end
  end

  # ── governance ─────────────────────────────────────────────────────────────

  @impl true
  def apply_network_policy(%Handle{}, %NetworkPolicy{}), do: {:error, :not_supported}

  @impl true
  def create_checkpoint(%Handle{}, _opts), do: {:error, :not_supported}

  @impl true
  def restore_checkpoint(%Handle{}, _checkpoint_id), do: {:error, :not_supported}

  # ── helpers ────────────────────────────────────────────────────────────────

  @doc """
  Resolve a sandbox path to the real directory on the runner machine.

  `/home/sprite` (and paths under it) map to the sandbox directory the
  daemon reports; a path an agent CLI validates in band — the ACP `cwd` —
  must be that real one, not the literal `/home/sprite`, which does not exist
  on the machine. Other absolute paths (`/tmp/...`) are already real and pass
  through. Falls back to the input if the daemon cannot be reached — the
  spawn that follows will surface the real error.
  """
  @spec host_path(Handle.t(), String.t()) :: String.t()
  def host_path(%Handle{} = handle, path) do
    home = "/home/sprite"

    if path == home or String.starts_with?(path, home <> "/") do
      case get(handle) do
        {:ok, %{raw: %{"path" => real}}} when is_binary(real) ->
          real <> binary_part(path, byte_size(home), byte_size(path) - byte_size(home))

        _ ->
          path
      end
    else
      path
    end
  end

  @doc "The runner id a sandbox name routes to."
  @spec runner_id(String.t()) :: {:ok, binary()} | {:error, {:invalid, term()}}
  def runner_id(name) do
    case Names.parse(name) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:invalid, {:not_a_runner_sandbox_name, name}}}
    end
  end

  defp rpc(name, payload, opts \\ []) do
    with {:ok, runner_id} <- runner_id(name) do
      Connection.call(runner_id, Map.put(payload, :name, name), opts)
    end
  end

  defp command(runner_id, name, session_id, ref) do
    %Command{
      provider: :runner,
      ref: ref,
      private: %{runner_id: runner_id, name: name, session_id: session_id}
    }
  end

  defp env_pairs(opts) do
    opts
    |> Keyword.get(:env, [])
    |> Enum.map(fn {k, v} -> [to_string(k), to_string(v)] end)
  end

  defp decode(b64) when is_binary(b64) do
    case Base.decode64(b64) do
      {:ok, bin} -> bin
      :error -> b64
    end
  end

  defp decode(_), do: ""
end
