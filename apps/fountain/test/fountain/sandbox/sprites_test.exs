defmodule Fountain.Sandbox.SpritesTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Sandbox.Command
  alias Fountain.Sandbox.Handle
  alias Fountain.Sandbox.NetworkPolicy
  alias Fountain.Sandbox.Session
  alias Fountain.Sandbox.Sprites, as: Adapter

  @name "fountain-abc12345-deadbeef"

  defp handle, do: %Handle{provider: :sprites, name: @name}

  defp stub_client do
    stub(Fountain.SpritesClient, :get!, fn -> %Sprites.Client{token: "test-token"} end)
  end

  describe "identity" do
    test "provider/0 and pure build_handle/1" do
      assert Adapter.provider() == :sprites
      assert %Handle{provider: :sprites, name: @name, private: nil} = Adapter.build_handle(@name)
    end

    test "capabilities: no :suspend (implicit scale-to-zero), no :checkpoint by default" do
      caps = Adapter.capabilities()
      assert MapSet.member?(caps, :network_policy)
      assert MapSet.member?(caps, :attach)
      refute MapSet.member?(caps, :suspend)
      refute MapSet.member?(caps, :checkpoint)
    end

    test "a handle's inspect never leaks the client token" do
      client = %Sprites.Client{token: "sekrit-token"}
      sprite = %Sprites.Sprite{name: @name, client: client}
      handle = %Handle{provider: :sprites, name: @name, private: sprite}

      refute inspect(handle) =~ "sekrit-token"
    end
  end

  describe "create/2" do
    test "wraps a created sprite in a handle" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:ok, %Sprites.Sprite{name: @name}} end)

      assert {:ok, %Handle{provider: :sprites, name: @name}} = Adapter.create(@name, [])
    end

    test "adopts on 409 — the name already exists" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:error, {:api_error, 409, %{}}} end)

      assert {:ok, %Handle{provider: :sprites, name: @name}} = Adapter.create(@name, [])
    end

    test "normalizes other errors" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:error, {:api_error, 500, %{}}} end)

      assert {:error, {:unavailable, {:http, 500, %{}}}} = Adapter.create(@name, [])
    end
  end

  describe "get/1" do
    test "normalizes status and keeps the raw body" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:ok, %{"status" => "running"}} end)

      assert {:ok, %{status: :running, raw: %{"status" => "running"}}} = Adapter.get(handle())
    end

    test "definitive not-found stays distinct from transient failures" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:error, {:not_found, %{}}} end)
      assert {:error, :not_found} = Adapter.get(handle())

      stub(Sprites, :get_sprite, fn _client, @name -> {:error, :timeout} end)
      assert {:error, {:unavailable, :timeout}} = Adapter.get(handle())
    end
  end

  describe "destroy/1, suspend/1, resume/1" do
    test "destroy rebuilds the SDK sprite from a bare handle" do
      stub_client()

      stub(Sprites, :destroy, fn %Sprites.Sprite{name: @name} -> :ok end)
      assert :ok = Adapter.destroy(handle())
    end

    test "suspend is a documented no-op" do
      assert :ok = Adapter.suspend(handle())
    end

    test "resume probes and returns the handle" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:ok, %{"status" => "ready"}} end)
      assert {:ok, %Handle{name: @name}} = Adapter.resume(handle())

      stub(Sprites, :get_sprite, fn _client, @name -> {:error, {:not_found, %{}}} end)
      assert {:error, :not_found} = Adapter.resume(handle())
    end
  end

  describe "list_all_names/0" do
    test "passes the full view through and refuses truncation" do
      names = MapSet.new(["a", "b"])
      stub(Fountain.SpritesClient, :list_all_sprite_names, fn -> {:ok, names} end)
      assert {:ok, ^names} = Adapter.list_all_names()

      stub(Fountain.SpritesClient, :list_all_sprite_names, fn -> {:error, :truncated} end)
      assert {:error, :truncated} = Adapter.list_all_names()

      stub(Fountain.SpritesClient, :list_all_sprite_names, fn ->
        {:error, {:api_error, 503, %{}}}
      end)

      assert {:error, {:unavailable, {:http, 503, %{}}}} = Adapter.list_all_names()
    end
  end

  describe "write_file/4" do
    test "writes through the SDK filesystem with the given mode" do
      stub_client()

      stub(Sprites, :filesystem, fn %Sprites.Sprite{name: @name}, "/" -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, "/home/sprite/.env", "A=1\n", mode: 0o600 ->
        :ok
      end)

      assert :ok = Adapter.write_file(handle(), "/home/sprite/.env", "A=1\n", mode: 0o600)
    end
  end

  describe "exec/4" do
    test "collects stdout and returns a nonzero exit as data, not an error" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, "bash", ["-lc", "x"], opts ->
        assert opts[:owner] == self()
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "he"})
        send(self(), {:stdout, %{ref: ref}, "llo"})
        send(self(), {:stderr, %{ref: ref}, "dropped"})
        send(self(), {:exit, %{ref: ref}, 3})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:ok, "hello", 3} = Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "stderr_to_stdout interleaves stderr into the output" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, "bash", _args, _opts ->
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "out"})
        send(self(), {:stderr, %{ref: ref}, "+err"})
        send(self(), {:exit, %{ref: ref}, 0})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:ok, "out+err", 0} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], stderr_to_stdout: true)
    end

    test "failure to start is a tagged error, never a raise" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts -> {:error, {:api_error, 401, %{}}} end)

      assert {:error, {:denied, {:http, 401, %{}}}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "a mid-run transport error frame is a tagged error" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts ->
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "partial"})
        send(self(), {:error, %{ref: ref}, :closed})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:error, {:provider, :sprites, :closed}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "timeout kills the command process and returns a transient error" do
      stub_client()
      lingering = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(lingering)

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts ->
        {:ok, %Sprites.Command{ref: make_ref(), pid: lingering}}
      end)

      assert {:error, {:unavailable, {:exec_timeout, 50}}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], timeout: 50)

      assert_receive {:DOWN, ^ref, :process, ^lingering, :killed}
    end
  end

  describe "spawn/4 and stdin" do
    test "wraps the SDK command, exposing its ref" do
      stub_client()
      sdk_ref = make_ref()

      stub(Sprites, :spawn, fn _sprite, "claude-agent-acp", [], _opts ->
        {:ok, %Sprites.Command{ref: sdk_ref}}
      end)

      assert {:ok, %Command{provider: :sprites, ref: ^sdk_ref}} =
               Adapter.spawn(handle(), "claude-agent-acp", [], stdin: true, detachable: true)
    end

    test "write_stdin is total: a dead command process yields :command_exited" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      command = %Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Command{ref: make_ref(), pid: dead}
      }

      assert {:error, :command_exited} = Adapter.write_stdin(command, "prompt\n")
    end

    test "write_stdin passes writes through when the command is alive" do
      sdk_command = %Sprites.Command{ref: make_ref(), pid: self()}
      command = %Command{provider: :sprites, ref: sdk_command.ref, private: sdk_command}

      stub(Sprites, :write, fn ^sdk_command, "data" -> :ok end)
      assert :ok = Adapter.write_stdin(command, "data")
    end

    test "stop_command stops a live command process and tolerates a dead one" do
      {:ok, agent} = Agent.start(fn -> :ok end)

      live = %Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Command{ref: make_ref(), pid: agent}
      }

      assert :ok = Adapter.stop_command(live)
      refute Process.alive?(agent)

      # Already stopped — total, no exit.
      assert :ok = Adapter.stop_command(live)

      # No private state at all (a handle that never carried the SDK struct).
      assert :ok = Adapter.stop_command(%Command{provider: :sprites, ref: make_ref()})
    end

    test "close_stdin on a dead command process is still :ok" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      command = %Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Command{ref: make_ref(), pid: dead}
      }

      assert :ok = Adapter.close_stdin(command)
    end
  end

  describe "sessions" do
    test "list_sessions normalizes to Session structs without is_active" do
      stub_client()
      created = ~U[2026-08-14 10:00:00Z]

      stub(Sprites, :list_sessions, fn %Sprites.Sprite{name: @name} ->
        {:ok,
         [
           %Sprites.Session{
             id: "sess-1",
             command: "claude-agent-acp",
             created: created,
             last_activity: created,
             is_active: false,
             tty: true
           }
         ]}
      end)

      assert {:ok, [%Session{id: "sess-1", command: "claude-agent-acp", tty: true} = session]} =
               Adapter.list_sessions(handle())

      assert session.created_at == created
      refute Map.has_key?(session, :is_active)
    end

    test "attach wraps the re-joined command" do
      stub_client()
      sdk_ref = make_ref()

      stub(Sprites, :attach_session, fn %Sprites.Sprite{name: @name}, "sess-1", opts ->
        assert opts[:stdin] == true
        {:ok, %Sprites.Command{ref: sdk_ref}}
      end)

      assert {:ok, %Command{provider: :sprites, ref: ^sdk_ref}} =
               Adapter.attach(handle(), "sess-1", stdin: true)
    end
  end

  describe "network policy" do
    test "an empty allowlist compiles to an explicit standalone deny-all" do
      assert [%Sprites.Policy.Rule{domain: "*", action: "deny", include: nil}] =
               Adapter.compile_rules([])
    end

    test "hosts compile to allow rules" do
      assert [
               %Sprites.Policy.Rule{domain: "api.example.com", action: "allow"},
               %Sprites.Policy.Rule{domain: "*.github.com", action: "allow"}
             ] = Adapter.compile_rules(["api.example.com", "*.github.com"])
    end

    test "apply_network_policy sends the compiled rules — allow: [] is not a no-op" do
      stub_client()

      expect(Sprites, :update_network_policy, fn %Sprites.Sprite{name: @name},
                                                 %Sprites.Policy{rules: rules} ->
        assert [%Sprites.Policy.Rule{domain: "*", action: "deny", include: nil}] = rules
        :ok
      end)

      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []})
    end
  end

  describe "checkpoints" do
    test "create drains the stream then resolves the id from the listing" do
      stub_client()
      stub(Sprites, :create_checkpoint, fn _sprite, [comment: "env x"] -> {:ok, []} end)

      stub(Sprites, :list_checkpoints, fn _sprite ->
        {:ok,
         [
           %Sprites.Checkpoint{id: "Current", create_time: ~U[2026-08-14 12:00:00Z]},
           %Sprites.Checkpoint{
             id: "v2",
             comment: "env x",
             create_time: ~U[2026-08-14 11:00:00Z]
           },
           %Sprites.Checkpoint{id: "v1", comment: "env x", create_time: ~U[2026-08-14 10:00:00Z]}
         ]}
      end)

      assert {:ok, "v2"} = Adapter.create_checkpoint(handle(), comment: "env x")
    end

    test "create with no resolvable id is an error" do
      stub_client()
      stub(Sprites, :create_checkpoint, fn _sprite, _opts -> {:ok, []} end)
      stub(Sprites, :list_checkpoints, fn _sprite -> {:ok, []} end)

      assert {:error, {:provider, :sprites, :no_checkpoint_id}} =
               Adapter.create_checkpoint(handle(), comment: "env x")
    end

    test "restore succeeds only when the stream reports no error element" do
      stub_client()
      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" -> {:ok, [%{type: "info"}]} end)
      assert :ok = Adapter.restore_checkpoint(handle(), "v1")
    end

    test "a reported-failed restore is an error, not :ok" do
      stub_client()

      stub(Sprites, :restore_checkpoint, fn _sprite, "v1" ->
        {:ok, [%{type: "info"}, %{type: "error", error: "no such checkpoint"}]}
      end)

      assert {:error, {:restore_failed, "no such checkpoint"}} =
               Adapter.restore_checkpoint(handle(), "v1")
    end
  end
end
