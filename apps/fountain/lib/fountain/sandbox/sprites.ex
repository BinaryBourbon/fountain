defmodule Fountain.Sandbox.Sprites do
  @moduledoc """
  The Sprites adapter: `Fountain.Sandbox` implemented against sprites.dev
  via the `sprites-ex` SDK.

  Everything Sprites-shaped lives here — the `{:api_error, status, body}`
  error tuples, the `%Sprites.Policy{}` rule compilation with its fail-open
  quirk, the checkpoint NDJSON streams, and the #603 stdin-write totality
  catch. Nothing outside `Fountain.Sandbox.Sprites.*` should reference the
  `Sprites` SDK.

  Capability notes:

    * `:suspend` is **not** advertised. Sprites parks implicitly
      (scale-to-zero), so `suspend/1` is a documented no-op and `resume/1`
      is a probe — waking happens as a side effect of the next exec. The
      flag is reserved for providers where suspension is an explicit,
      billable-state-changing API call.
    * `:checkpoint` is advertised only while `:checkpoint_creation_enabled`
      is set — a Sprites checkpoint id is scoped to the sprite that created
      it, so cross-sprite warm starts cannot work (#654).
  """

  @behaviour Fountain.Sandbox

  alias Fountain.Sandbox.Command
  alias Fountain.Sandbox.Handle
  alias Fountain.Sandbox.NetworkPolicy
  alias Fountain.Sandbox.Session
  alias Fountain.Sandbox.Sprites.Errors

  require Logger

  @impl true
  def provider, do: :sprites

  @impl true
  def capabilities do
    MapSet.new([:network_policy, :attach, :tty] ++ checkpoint_capabilities())
  end

  defp checkpoint_capabilities do
    if Application.get_env(:fountain, :checkpoint_creation_enabled, false),
      do: [:checkpoint],
      else: []
  end

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @impl true
  def build_handle(name) when is_binary(name) do
    %Handle{provider: :sprites, name: name}
  end

  @impl true
  def create(name, opts) when is_binary(name) do
    client = Fountain.SpritesClient.get!()

    case Sprites.create(client, name, opts) do
      {:ok, %Sprites.Sprite{} = sprite} ->
        {:ok, wrap(sprite)}

      # The sprite already exists — adopt it. Names are unique per token and
      # Fountain minted this one, so "already there" means an earlier attempt
      # (or a retry after a lost response) won the race.
      {:error, {:api_error, 409, _body}} ->
        {:ok, wrap(Sprites.sprite(client, name))}

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def get(%Handle{} = handle) do
    client = Fountain.SpritesClient.get!()

    case Sprites.get_sprite(client, handle.name) do
      {:ok, body} -> {:ok, %{status: normalize_status(body), raw: body}}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def destroy(%Handle{} = handle) do
    case Sprites.destroy(sprite_of(handle)) do
      :ok -> :ok
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def list_all_names do
    case Fountain.SpritesClient.list_all_sprite_names() do
      {:ok, names} -> {:ok, names}
      {:error, :truncated} -> {:error, :truncated}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def suspend(%Handle{}), do: :ok

  @impl true
  def resume(%Handle{} = handle) do
    case get(handle) do
      {:ok, _info} -> {:ok, handle}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── filesystem ─────────────────────────────────────────────────────────────

  @impl true
  def write_file(%Handle{} = handle, path, data, opts) do
    fs = Sprites.filesystem(sprite_of(handle), "/")

    case Sprites.Filesystem.write(fs, path, data, Keyword.take(opts, [:mode])) do
      :ok -> :ok
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  # ── exec ───────────────────────────────────────────────────────────────────

  @impl true
  def exec(%Handle{} = handle, cmd, args, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)
    spawn_opts = Keyword.take(opts, [:env, :dir]) ++ [owner: self()]

    case Sprites.spawn(sprite_of(handle), cmd, args, spawn_opts) do
      {:ok, %Sprites.Command{} = command} ->
        collect(command, [], stderr_to_stdout, timeout)

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  # The SDK's own blocking `Sprites.cmd/4` raises on failure-to-start, on a
  # mid-run transport error and on timeout, which forced callers (and
  # `Fountain.Retry`) to treat every raise as transient. Collecting here
  # instead keeps the contract total: a nonzero exit is data, everything
  # else is a tagged error.
  defp collect(%Sprites.Command{ref: ref} = command, acc, stderr_to_stdout, timeout) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        collect(command, [acc | data], stderr_to_stdout, timeout)

      {:stderr, %{ref: ^ref}, data} when stderr_to_stdout ->
        collect(command, [acc | data], stderr_to_stdout, timeout)

      {:stderr, %{ref: ^ref}, _data} ->
        collect(command, acc, stderr_to_stdout, timeout)

      {:exit, %{ref: ^ref}, code} ->
        {:ok, IO.iodata_to_binary(acc), code}

      {:error, %{ref: ^ref}, reason} ->
        {:error, Errors.normalize(reason)}
    after
      timeout ->
        # Stop the command process so it cannot keep streaming into the
        # caller's mailbox after we have given up on it.
        Process.exit(command.pid, :kill)
        {:error, {:unavailable, {:exec_timeout, timeout}}}
    end
  end

  @impl true
  def spawn(%Handle{} = handle, cmd, args, opts) do
    case Sprites.spawn(sprite_of(handle), cmd, args, opts) do
      {:ok, %Sprites.Command{} = command} -> {:ok, wrap_command(command)}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def write_stdin(%Command{provider: :sprites} = command, data) do
    Sprites.write(sdk_command(command), data)
  catch
    # `Sprites.write/2` is a bare GenServer.call into the command process,
    # which stops :normal the moment the runtime's exit frame arrives — a
    # write landing after that exits the *caller* instead of returning an
    # error (#603). :normal is the command stopping mid-call; :noproc is it
    # having stopped before the call was sent. Both mean the same thing:
    # there is no runtime left to read this data.
    :exit, {reason, {GenServer, :call, _args}} when reason in [:normal, :noproc, :shutdown] ->
      {:error, :command_exited}

    :exit, {reason, {GenServer, :call, _args}} ->
      {:error, {:write_failed, reason}}

    :exit, reason ->
      {:error, {:write_failed, reason}}
  end

  @impl true
  def close_stdin(%Command{provider: :sprites} = command) do
    Sprites.close_stdin(sdk_command(command))
  end

  # ── sessions ───────────────────────────────────────────────────────────────

  @impl true
  def list_sessions(%Handle{} = handle) do
    case Sprites.list_sessions(sprite_of(handle)) do
      {:ok, sessions} -> {:ok, Enum.map(sessions, &to_session/1)}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @impl true
  def attach(%Handle{} = handle, session_id, opts) do
    case Sprites.attach_session(sprite_of(handle), session_id, opts) do
      {:ok, %Sprites.Command{} = command} -> {:ok, wrap_command(command)}
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  # ── network policy ─────────────────────────────────────────────────────────

  @impl true
  def apply_network_policy(%Handle{} = handle, %NetworkPolicy{allow: allow}) do
    policy = %Sprites.Policy{rules: compile_rules(allow)}

    case Sprites.update_network_policy(sprite_of(handle), policy) do
      :ok -> :ok
      {:error, reason} -> {:error, Errors.normalize(reason)}
    end
  end

  @doc """
  Compile an intent-level allowlist into Sprites policy rules.

  Sprites interprets a bare `rules: []` as "no enforcement" (allow-all), so
  an empty allowlist must be sent as an explicit deny-all instead — and the
  deny rule stands alone, without `include: "defaults"`, since pulling in
  Sprites' own default allowances would defeat it.

  Public and pure so tests can pin the deny-all compilation without a live
  API.
  """
  @spec compile_rules([String.t()]) :: [Sprites.Policy.Rule.t()]
  def compile_rules([]), do: [%Sprites.Policy.Rule{domain: "*", action: "deny"}]

  def compile_rules(allow) when is_list(allow) do
    Enum.map(allow, &%Sprites.Policy.Rule{domain: &1, action: "allow"})
  end

  # ── checkpoints ────────────────────────────────────────────────────────────

  @impl true
  def create_checkpoint(%Handle{} = handle, opts) do
    sprite = sprite_of(handle)
    comment = Keyword.get(opts, :comment, "")

    case Sprites.create_checkpoint(sprite, comment: comment) do
      {:ok, stream} ->
        # Drain first: the checkpoint is not on the server until the stream
        # completes, so listing before this races the upload.
        Stream.run(stream)

        case newest_checkpoint_id(sprite, comment) do
          nil -> {:error, {:provider, :sprites, :no_checkpoint_id}}
          id -> {:ok, id}
        end

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  # The id comes from `list_checkpoints/1`, not from the creation stream.
  #
  # The stream is `%Sprites.StreamMessage{type:, data:, error:}` and the id
  # is *prose inside `data`* — an extractor that pattern-matched map keys out
  # of it resolved every checkpoint to nil, so `environments.checkpoint_id`
  # was never written (#652). `list_checkpoints/1` returns typed structs
  # instead. Two traps: the list includes a synthetic "Current" entry for the
  # live filesystem (always the newest thing there, not a saved checkpoint),
  # and `Sprites.Checkpoint` does not implement Access, so it must be `c.id`.
  defp newest_checkpoint_id(sprite, comment) do
    case Sprites.list_checkpoints(sprite) do
      {:ok, checkpoints} when is_list(checkpoints) ->
        saved = Enum.reject(checkpoints, &(&1.id == "Current"))

        case Enum.filter(saved, &(&1.comment == comment)) do
          [] -> saved
          ours -> ours
        end
        |> newest()

      other ->
        Logger.warning("list_checkpoints after create returned #{inspect(other)}")
        nil
    end
  end

  defp newest([]), do: nil

  defp newest(checkpoints) do
    checkpoints
    |> Enum.max_by(& &1.create_time, DateTime, fn -> nil end)
    |> case do
      nil -> nil
      checkpoint -> checkpoint.id
    end
  end

  @impl true
  def restore_checkpoint(%Handle{} = handle, checkpoint_id) when is_binary(checkpoint_id) do
    case Sprites.restore_checkpoint(sprite_of(handle), checkpoint_id) do
      {:ok, stream} ->
        scan_restore_stream(stream)

      {:error, reason} ->
        {:error, Errors.normalize(reason)}
    end
  end

  # A failed restore is an ordinary *element* of the stream, not an
  # {:error, _} from the call — the library hands back
  # `%Sprites.StreamMessage{type: "error", error: "..."}` and keeps going.
  # Draining without looking would report every failure as a success, and
  # the caller treats success as "the sandbox is already provisioned": it
  # would skip packages, clones, the setup script *and the network policy*.
  defp scan_restore_stream(stream) do
    case Enum.find(stream, &stream_error?/1) do
      nil -> :ok
      message -> {:error, {:restore_failed, Map.get(message, :error) || message}}
    end
  rescue
    e -> {:error, {:provider, :sprites, {:stream_raised, e}}}
  end

  defp stream_error?(%{type: "error"}), do: true
  defp stream_error?(%{error: error}) when is_binary(error) and error != "", do: true
  defp stream_error?(_), do: false

  # ── internals ──────────────────────────────────────────────────────────────

  # Operations must work on any handle whose provider/name are set: a handle
  # that crossed a serialization boundary (or came straight from
  # build_handle/1) has no private state, so the SDK sprite is rebuilt from
  # the name lazily. A handle fresh from create/2 keeps the SDK struct to
  # avoid rebuilding the HTTP client per call.
  defp sprite_of(%Handle{provider: :sprites, private: %Sprites.Sprite{} = sprite}), do: sprite

  defp sprite_of(%Handle{provider: :sprites, name: name}) do
    Sprites.sprite(Fountain.SpritesClient.get!(), name)
  end

  defp sdk_command(%Command{private: %Sprites.Command{} = command}), do: command

  defp wrap(%Sprites.Sprite{} = sprite) do
    %Handle{provider: :sprites, name: sprite.name, private: sprite}
  end

  defp wrap_command(%Sprites.Command{} = command) do
    %Command{provider: :sprites, ref: command.ref, private: command}
  end

  defp to_session(%Sprites.Session{} = session) do
    %Session{
      id: session.id,
      command: session.command,
      created_at: session.created,
      last_activity_at: session.last_activity,
      tty: session.tty
    }
  end

  # The platform's status vocabulary is not part of our contract; anything
  # unrecognized is :unknown and the raw body rides alongside.
  defp normalize_status(%{"status" => status}) when status in ["running", "ready", "active"],
    do: :running

  defp normalize_status(%{"status" => status}) when status in ["suspended", "paused", "stopped"],
    do: :suspended

  defp normalize_status(_body), do: :unknown
end
