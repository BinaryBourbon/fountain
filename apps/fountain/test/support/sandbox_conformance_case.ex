defmodule Fountain.SandboxConformanceCase do
  @moduledoc """
  The executable form of the `Fountain.Sandbox` contract: a shared suite
  every adapter must pass.

  Usage:

      defmodule Fountain.Sandbox.FakeConformanceTest do
        use Fountain.SandboxConformanceCase,
          adapter: Fountain.Sandbox.Fake,
          fixtures: %{
            exec_ok: {"emit", ["out:hello"], "hello"},
            exec_fail: {"emit", ["out:oops", "exit:3"], 3},
            spawn_ok: {"emit", ["out:hello", "exit:0"]},
            spawn_drop: {"emit", ["out:partial", "drop"]},
            spawn_stay: {"emit", ["out:ready", "stay"]}
          }

        setup do
          Fountain.Sandbox.Fake.reset()
          :ok
        end
      end

  `fixtures` supplies the adapter-appropriate command vocabulary (the Fake
  speaks its scripted instructions; a live adapter would use `bash -lc`):

    * `exec_ok` — `{cmd, args, expected_stdout}`, exits 0
    * `exec_fail` — `{cmd, args, nonzero_exit_code}`
    * `spawn_ok` — emits some stdout then exits 0
    * `spawn_drop` — the transport closes without an exit frame (optional;
      pins the closes-without-exit-reads-as-zero rule)
    * `spawn_stay` — emits stdout then stays alive until stdin EOF
      (needed for the write-totality and attach-replay tests)

  Semantics pinned here and nowhere else: create idempotency, the
  not-found/transient distinction, destroy tolerance, full-view listing,
  exec-never-raises with nonzero-exit-as-data, the owner-message frame
  contract with exactly one terminal frame, stdin-write totality (#603),
  attach replay-from-start, and suspend/resume totality.
  """

  defmacro __using__(opts) do
    quote do
      use ExUnit.Case, async: false

      @adapter unquote(opts[:adapter])
      @fixtures unquote(opts[:fixtures])

      defp conformance_name do
        "conformance-#{System.unique_integer([:positive])}"
      end

      defp created_handle do
        name = conformance_name()
        {:ok, handle} = @adapter.create(name, [])
        handle
      end

      use Fountain.SandboxConformanceCase.Identity, unquote(opts)
      use Fountain.SandboxConformanceCase.Lifecycle, unquote(opts)
      use Fountain.SandboxConformanceCase.Exec, unquote(opts)
      use Fountain.SandboxConformanceCase.Streaming, unquote(opts)
      use Fountain.SandboxConformanceCase.Governance, unquote(opts)
    end
  end
end

defmodule Fountain.SandboxConformanceCase.Identity do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      describe "#{inspect(adapter)} conformance: identity" do
        test "build_handle/1 is pure and provider-tagged" do
          name = conformance_name()
          handle = @adapter.build_handle(name)
          assert handle.provider == @adapter.provider()
          assert handle.name == name
        end

        test "capabilities/0 is a MapSet of known capabilities" do
          caps = @adapter.capabilities()
          assert %MapSet{} = caps

          known = MapSet.new([:suspend, :network_policy, :checkpoint, :attach, :tty])
          assert MapSet.subset?(caps, known)
        end
      end
    end
  end
end

defmodule Fountain.SandboxConformanceCase.Lifecycle do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      describe "#{inspect(adapter)} conformance: lifecycle" do
        test "create is name-keyed and idempotent-adopting" do
          name = conformance_name()
          assert {:ok, first} = @adapter.create(name, [])
          assert {:ok, second} = @adapter.create(name, [])
          assert first.name == second.name
          assert {:ok, %{status: _}} = @adapter.get(first)
        end

        test "get on a nonexistent sandbox is exactly {:error, :not_found}" do
          assert {:error, :not_found} = @adapter.get(@adapter.build_handle(conformance_name()))
        end

        test "destroy tolerates an already-gone sandbox and is definitive" do
          assert :ok = @adapter.destroy(@adapter.build_handle(conformance_name()))

          handle = created_handle()
          assert :ok = @adapter.destroy(handle)
          assert {:error, :not_found} = @adapter.get(handle)
        end

        test "list_all_names returns the full account view as a MapSet" do
          handle = created_handle()
          assert {:ok, %MapSet{} = names} = @adapter.list_all_names()
          assert MapSet.member?(names, handle.name)
        end

        test "suspend and resume are total; resume returns a usable handle" do
          handle = created_handle()
          assert :ok = @adapter.suspend(handle)
          assert {:ok, resumed} = @adapter.resume(handle)
          assert {:ok, %{status: _}} = @adapter.get(resumed)
        end
      end
    end
  end
end

defmodule Fountain.SandboxConformanceCase.Exec do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      describe "#{inspect(adapter)} conformance: exec" do
        test "collects output; zero exit" do
          {cmd, args, expected} = @fixtures.exec_ok
          assert {:ok, out, 0} = @adapter.exec(created_handle(), cmd, args, [])
          assert out =~ expected
        end

        test "a nonzero exit is data, not an error — and never a raise" do
          {cmd, args, code} = @fixtures.exec_fail
          assert {:ok, _out, ^code} = @adapter.exec(created_handle(), cmd, args, [])
        end
      end
    end
  end
end

defmodule Fountain.SandboxConformanceCase.Streaming do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter], fixtures: opts[:fixtures]] do
      describe "#{inspect(adapter)} conformance: streaming commands" do
        test "frames carry the command ref; output precedes exactly one terminal frame" do
          {cmd, args} = @fixtures.spawn_ok
          handle = created_handle()

          assert {:ok, command} = @adapter.spawn(handle, cmd, args, owner: self(), stdin: false)
          ref = command.ref

          assert_receive {:stdout, %{ref: ^ref}, data}, 1_000
          assert is_binary(data)
          assert_receive {:exit, %{ref: ^ref}, 0}, 1_000
          refute_receive {:exit, %{ref: ^ref}, _}, 50
        end

        if fixtures[:spawn_drop] do
          test "a stream that closes without an exit frame surfaces as exit 0" do
            {cmd, args} = @fixtures.spawn_drop
            handle = created_handle()

            assert {:ok, command} = @adapter.spawn(handle, cmd, args, owner: self(), stdin: false)
            ref = command.ref

            assert_receive {:stdout, %{ref: ^ref}, _}, 1_000
            assert_receive {:exit, %{ref: ^ref}, 0}, 1_000
          end
        end

        test "write_stdin is total: an exited command yields :command_exited (#603)" do
          {cmd, args} = @fixtures.spawn_ok
          handle = created_handle()

          assert {:ok, command} = @adapter.spawn(handle, cmd, args, owner: self(), stdin: true)
          ref = command.ref
          assert_receive {:exit, %{ref: ^ref}, 0}, 1_000

          # The command is gone; the write must come back as an error, not
          # take this process down.
          assert {:error, :command_exited} = @adapter.write_stdin(command, "late\n")
        end

        test "stdin round-trips into a live command; EOF ends it" do
          {cmd, args} = @fixtures.spawn_stay
          handle = created_handle()

          assert {:ok, command} = @adapter.spawn(handle, cmd, args, owner: self(), stdin: true)
          ref = command.ref
          assert_receive {:stdout, %{ref: ^ref}, _ready}, 1_000

          assert :ok = @adapter.write_stdin(command, "ping")
          assert_receive {:stdout, %{ref: ^ref}, echoed}, 1_000
          assert echoed =~ "ping"

          assert :ok = @adapter.close_stdin(command)
          assert_receive {:exit, %{ref: ^ref}, 0}, 1_000
        end

        test "stop_command is total and tears down the local end" do
          {cmd, args} = @fixtures.spawn_stay
          handle = created_handle()

          assert {:ok, command} = @adapter.spawn(handle, cmd, args, owner: self(), stdin: true)
          assert :ok = @adapter.stop_command(command)
          # A second stop of an already-stopped command must still be :ok.
          assert :ok = @adapter.stop_command(command)
        end
      end
    end
  end
end

defmodule Fountain.SandboxConformanceCase.Governance do
  @moduledoc false
  defmacro __using__(opts) do
    quote bind_quoted: [adapter: opts[:adapter]] do
      if MapSet.member?(adapter.capabilities(), :attach) do
        describe "#{inspect(adapter)} conformance: detachable sessions" do
          test "attach replays buffered output from the start, then tails" do
            {cmd, args} = @fixtures.spawn_stay
            handle = created_handle()

            assert {:ok, command} = @adapter.spawn(handle, cmd, args, owner: self(), stdin: true)
            first_ref = command.ref
            assert_receive {:stdout, %{ref: ^first_ref}, pre_attach}, 1_000

            assert {:ok, [session | _]} = @adapter.list_sessions(handle)

            # A different owner attaches: it must see the pre-attach output
            # replayed from byte zero — the caller's byte-skip arithmetic
            # depends on it — and then live frames.
            test_pid = self()

            attacher =
              spawn(fn ->
                {:ok, attached} = @adapter.attach(handle, session.id, owner: self(), stdin: true)
                ref = attached.ref

                receive do
                  {:stdout, %{ref: ^ref}, replayed} -> send(test_pid, {:replayed, replayed})
                end

                receive do
                  {:stdout, %{ref: ^ref}, live} -> send(test_pid, {:tailed, live})
                end
              end)

            assert_receive {:replayed, replayed}, 1_000
            assert replayed == pre_attach

            # New output reaches both the original owner and the attacher.
            assert :ok = @adapter.write_stdin(command, "after-attach")
            assert_receive {:stdout, %{ref: ^first_ref}, _}, 1_000
            assert_receive {:tailed, tailed}, 1_000
            assert tailed =~ "after-attach"

            ref = Process.monitor(attacher)
            assert_receive {:DOWN, ^ref, :process, _, _}, 1_000
          end
        end
      end

      if MapSet.member?(adapter.capabilities(), :network_policy) do
        describe "#{inspect(adapter)} conformance: network policy" do
          test "an empty allowlist is accepted — deny-all, never a silent no-op" do
            handle = created_handle()

            assert :ok =
                     @adapter.apply_network_policy(handle, %Fountain.Sandbox.NetworkPolicy{
                       allow: []
                     })

            assert :ok =
                     @adapter.apply_network_policy(handle, %Fountain.Sandbox.NetworkPolicy{
                       allow: ["api.example.com"]
                     })
          end
        end
      end

      unless MapSet.member?(adapter.capabilities(), :checkpoint) do
        describe "#{inspect(adapter)} conformance: capability coherence" do
          test "unadvertised checkpointing refuses rather than pretending" do
            handle = created_handle()
            assert {:error, :not_supported} = @adapter.create_checkpoint(handle, [])
            assert {:error, :not_supported} = @adapter.restore_checkpoint(handle, "cp-1")
          end
        end
      end
    end
  end
end
