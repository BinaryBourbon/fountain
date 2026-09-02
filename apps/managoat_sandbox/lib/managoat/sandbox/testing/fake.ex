defmodule Managoat.Sandbox.Fake do
  @moduledoc """
  A real, in-memory `Managoat.Sandbox` adapter.

  It lives under `lib/`, not `test/support`, on purpose: it is compiled in
  every environment so that a host application's own suite can run
  `Managoat.Sandbox.ConformanceCase` against it, drive a provisioning path
  without a network, or register it in the adapter map — the same way
  `Ecto.Adapters.SQL.Sandbox` ships inside Ecto rather than beside it.

  Three jobs:

    * prove the conformance suite is not Sprites-shaped — a second adapter
      has to pass it;
    * exercise the owner-message contract *for real* — commands are actual
      processes emitting the `{:stdout | :stderr | :exit, %{ref: ref}, _}`
      frames, where most tests hand-craft them and can silently drift;
    * be the reference implementation the next adapter's author reads.

  Commands speak a tiny scripted vocabulary instead of a shell — each arg is
  an instruction:

    * `"out:<data>"` / `"err:<data>"` — emit a stdout/stderr frame
    * `"exit:<code>"` — emit the exit frame and stop
    * `"stay"` — keep running: echo stdin writes back as `echo:<data>`
      stdout frames, exit 0 on stdin EOF
    * `"drop"` — the transport closes without an exit frame; per the
      contract the adapter must surface that as exit 0

  A script with no terminal instruction exits 0. State lives in a named
  Agent; call `reset/0` in a setup block. Sessions buffer every emitted
  frame, and `attach/3` replays the buffer from the start before tailing —
  the load-bearing semantic the conformance suite pins.
  """

  @behaviour Managoat.Sandbox

  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy
  alias Managoat.Sandbox.Session

  @registry __MODULE__.Registry

  # ── test-side controls ─────────────────────────────────────────────────────

  def reset do
    case Agent.start(fn -> %{} end, name: @registry) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> Agent.update(@registry, fn _ -> %{} end)
    end
  end

  @doc "The network policy last applied to `name`, or nil."
  def policy(name), do: Agent.get(@registry, &get_in(&1, [name, :policy]))

  @doc "The file contents written at `path`, or nil."
  def file(name, path), do: Agent.get(@registry, &get_in(&1, [name, :files, path]))

  # ── identity ───────────────────────────────────────────────────────────────

  @impl true
  def provider, do: :fake

  @impl true
  def capabilities, do: MapSet.new([:suspend, :network_policy, :attach, :public_url])

  @impl true
  def build_handle(name) when is_binary(name), do: %Handle{provider: :fake, name: name}

  # ── lifecycle ──────────────────────────────────────────────────────────────

  @impl true
  def create(name, _opts) when is_binary(name) do
    Agent.update(@registry, fn state ->
      Map.put_new(state, name, %{status: :running, files: %{}, policy: nil, sessions: %{}})
    end)

    {:ok, build_handle(name)}
  end

  @impl true
  # The Fake advertises :public_url so the conformance suite exercises the
  # capability without a network. Like a real adapter it looks the sandbox up
  # first, so asking about one that does not exist is not-found rather than a
  # confidently wrong URL.
  def public_url(%Handle{name: name}) do
    case Agent.get(@registry, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      _ -> {:ok, "https://#{name}.fake.test"}
    end
  end

  @impl true
  def get(%Handle{name: name}) do
    case Agent.get(@registry, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      %{status: status} -> {:ok, %{status: status, raw: %{}}}
    end
  end

  @impl true
  def destroy(%Handle{name: name}) do
    Agent.update(@registry, &Map.delete(&1, name))
    :ok
  end

  @impl true
  def list_all_names do
    {:ok, Agent.get(@registry, &(&1 |> Map.keys() |> MapSet.new()))}
  end

  @impl true
  def suspend(%Handle{name: name}) do
    with_sandbox(name, fn _ ->
      Agent.update(@registry, &put_in(&1, [name, :status], :suspended))
      :ok
    end)
  end

  @impl true
  def resume(%Handle{name: name} = handle) do
    with_sandbox(name, fn _ ->
      Agent.update(@registry, &put_in(&1, [name, :status], :running))
      {:ok, handle}
    end)
  end

  # ── filesystem ─────────────────────────────────────────────────────────────

  @impl true
  def write_file(%Handle{name: name}, path, data, _opts) do
    with_sandbox(name, fn _ ->
      Agent.update(@registry, &put_in(&1, [name, :files, path], IO.iodata_to_binary(data)))
      :ok
    end)
  end

  # ── exec ───────────────────────────────────────────────────────────────────

  @impl true
  def exec(%Handle{name: name}, _cmd, args, opts) do
    with_sandbox(name, fn _ ->
      stderr_to_stdout = Keyword.get(opts, :stderr_to_stdout, false)

      {out, code} =
        Enum.reduce(script(args), {[], nil}, fn
          {:stdout, data}, {acc, code} -> {[acc | data], code}
          {:stderr, data}, {acc, code} when stderr_to_stdout -> {[acc | data], code}
          {:stderr, _data}, acc_code -> acc_code
          {:exit, code}, {acc, nil} -> {acc, code}
          _other, acc_code -> acc_code
        end)

      {:ok, IO.iodata_to_binary(out), code || 0}
    end)
  end

  @impl true
  def spawn(%Handle{name: name}, cmd, args, opts) do
    with_sandbox(name, fn _ ->
      owner = Keyword.get(opts, :owner, self())
      ref = make_ref()
      session_id = "fake-sess-#{System.unique_integer([:positive])}"

      pid =
        Kernel.spawn(fn ->
          run_command(name, session_id, script(args))
        end)

      Agent.update(@registry, fn state ->
        put_in(state, [name, :sessions, session_id], %{
          # The full line, as the runner daemon and the sprites API report it —
          # a session's conversation tag lives in its argv.
          command: Enum.join([cmd | args], " "),
          pid: pid,
          exit: nil,
          buffer: [],
          subscribers: [{owner, ref}]
        })
      end)

      send(pid, :go)

      {:ok,
       %Command{provider: :fake, ref: ref, private: %{pid: pid, name: name, session: session_id}}}
    end)
  end

  @impl true
  def write_stdin(%Command{private: %{pid: pid}}, data) do
    if Process.alive?(pid) do
      send(pid, {:stdin, IO.iodata_to_binary(data)})
      :ok
    else
      {:error, :command_exited}
    end
  end

  @impl true
  def close_stdin(%Command{private: %{pid: pid}}) do
    send(pid, :eof)
    :ok
  end

  @impl true
  def stop_command(%Command{private: %{pid: pid}}) do
    Process.exit(pid, :kill)
    :ok
  end

  # ── sessions ───────────────────────────────────────────────────────────────

  @impl true
  def list_sessions(%Handle{name: name}) do
    with_sandbox(name, fn sandbox ->
      sessions =
        Enum.map(sandbox.sessions, fn {id, s} ->
          %Session{id: id, command: s.command}
        end)

      {:ok, sessions}
    end)
  end

  @impl true
  def attach(%Handle{name: name}, session_id, opts) do
    owner = Keyword.get(opts, :owner, self())
    ref = make_ref()

    case Agent.get(@registry, &get_in(&1, [name, :sessions, session_id])) do
      nil ->
        {:error, :not_found}

      session ->
        # Replay the whole buffer from the start, then tail: the byte-skip
        # de-duplication callers do is only correct against exactly this.
        Enum.each(Enum.reverse(session.buffer), fn {stream, data} ->
          send(owner, {stream, %{ref: ref}, data})
        end)

        if session.exit do
          send(owner, {:exit, %{ref: ref}, session.exit})
        else
          Agent.update(@registry, fn state ->
            update_in(state, [name, :sessions, session_id, :subscribers], &[{owner, ref} | &1])
          end)
        end

        {:ok,
         %Command{
           provider: :fake,
           ref: ref,
           private: %{pid: session.pid, name: name, session: session_id}
         }}
    end
  end

  # ── governance ─────────────────────────────────────────────────────────────

  @impl true
  def apply_network_policy(%Handle{name: name}, %NetworkPolicy{} = policy) do
    with_sandbox(name, fn _ ->
      Agent.update(@registry, &put_in(&1, [name, :policy], policy))
      :ok
    end)
  end

  @impl true
  def create_checkpoint(%Handle{}, _opts), do: {:error, :not_supported}

  @impl true
  def restore_checkpoint(%Handle{}, _checkpoint_id), do: {:error, :not_supported}

  # ── command process ────────────────────────────────────────────────────────

  defp run_command(name, session_id, instructions) do
    receive do
      :go -> :ok
    end

    Enum.each(instructions, fn
      {:stdout, data} -> emit(name, session_id, :stdout, data)
      {:stderr, data} -> emit(name, session_id, :stderr, data)
      {:exit, code} -> finish(name, session_id, code)
      :drop -> finish(name, session_id, 0)
      :stay -> stay(name, session_id)
    end)

    unless Enum.any?(instructions, &(&1 in [:stay, :drop] or match?({:exit, _}, &1))) do
      finish(name, session_id, 0)
    end
  end

  defp stay(name, session_id) do
    receive do
      {:stdin, data} ->
        emit(name, session_id, :stdout, "echo:" <> data)
        stay(name, session_id)

      :eof ->
        finish(name, session_id, 0)
    end
  end

  defp emit(name, session_id, stream, data) do
    session = Agent.get(@registry, &get_in(&1, [name, :sessions, session_id]))

    Agent.update(@registry, fn state ->
      update_in(state, [name, :sessions, session_id, :buffer], &[{stream, data} | &1])
    end)

    Enum.each(session.subscribers, fn {owner, ref} ->
      send(owner, {stream, %{ref: ref}, data})
    end)
  end

  defp finish(name, session_id, code) do
    session = Agent.get(@registry, &get_in(&1, [name, :sessions, session_id]))

    Agent.update(@registry, fn state ->
      put_in(state, [name, :sessions, session_id, :exit], code)
    end)

    Enum.each(session.subscribers, fn {owner, ref} ->
      send(owner, {:exit, %{ref: ref}, code})
    end)

    exit(:normal)
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp with_sandbox(name, fun) do
    case Agent.get(@registry, &Map.get(&1, name)) do
      nil -> {:error, :not_found}
      sandbox -> fun.(sandbox)
    end
  end

  defp script(args) do
    Enum.map(args, fn
      "out:" <> data -> {:stdout, data}
      "err:" <> data -> {:stderr, data}
      "exit:" <> code -> {:exit, String.to_integer(code)}
      "stay" -> :stay
      "drop" -> :drop
    end)
  end
end
