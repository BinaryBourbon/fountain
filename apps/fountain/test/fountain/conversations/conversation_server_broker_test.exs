defmodule Fountain.Conversations.ConversationServerBrokerTest do
  # Egress credential brokerage through a real ConversationServer (ADR 0019
  # gate 1a). Two guarantees, one per describe: an unbrokered conversation is
  # byte-for-byte what it was — the broker is never called — and a brokered
  # one gets placeholders, a process-only proxy address, the network floor,
  # the CA, and a clone that can reach GitHub through the proxy.
  use Fountain.ConversationServerCase

  alias Fountain.Environments

  @dek <<0::256>>
  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, env_vars: %{"FROM_ENVIRONMENT" => "yes"})

    {:ok, _} =
      Environments.upsert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_real"}, @dek)

    {:ok, _} =
      Environments.upsert_secret(env, %{"key" => "DATABASE_URL", "value" => "postgres://x"}, @dek)

    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    previous =
      for key <- [:broker_listen_port, :broker_proxy_url, :broker_tenants],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    {:ok, user: user, agent: agent, env: env}
  end

  defp configure_broker(tenants) do
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Application.put_env(:fountain, :broker_tenants, tenants)
  end

  defp stub_turn_boundary do
    test = self()
    ref = make_ref()

    Mimic.stub(Fountain.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Fountain.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Fountain.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Fountain.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Fountain.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
    ref
  end

  defp stage_events(conv_id, stage) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == stage))
  end

  describe "an unbrokered conversation" do
    test "never calls the broker, and the sandbox gets the real value", %{
      user: user,
      agent: agent
    } do
      # Configured, but this tenant is not on the ratchet.
      configure_broker(["someone-else"])

      conv = insert_conversation(user_id: user.id, agent: agent)
      stub_happy_sprite()
      _ref = stub_turn_boundary()

      reject(Fountain.Broker, :preflight, 0)
      reject(Fountain.Broker, :prepare, 4)
      reject(Fountain.Broker, :ca_pem, 0)
      reject(Fountain.Broker, :release, 1)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)

      assert {"GITHUB_TOKEN", "ghp_real"} in spawn_env
      refute Enum.any?(spawn_env, &match?({"HTTPS_PROXY", _}, &1))
      assert stage_events(conv.id, "broker") == []
    end

    test "with BROKER_LISTEN_PORT blank the ratchet is inert too", %{user: user, agent: agent} do
      Application.delete_env(:fountain, :broker_listen_port)
      Application.put_env(:fountain, :broker_tenants, [user.id])

      conv = insert_conversation(user_id: user.id, agent: agent)
      stub_happy_sprite()
      _ref = stub_turn_boundary()

      reject(Fountain.Broker, :prepare, 4)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      assert {"GITHUB_TOKEN", "ghp_real"} in Keyword.fetch!(opts, :env)
    end
  end

  describe "a brokered conversation" do
    setup %{user: user} do
      configure_broker([user.id])
      :ok
    end

    test "placeholders in the sandbox, the value at the broker, the token off the disk", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn conv_id, _user_id, brokered, _bindings ->
        send(test, {:prepared, conv_id, brokered})
        {:ok, @session}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, env ->
        send(test, {:env_file, env})
        :ok
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :apply_network_policy, fn _h, policy ->
        send(test, {:policy, policy})
        :ok
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :write_file, fn _h, path, data, _opts ->
        send(test, {:wrote, path, data})
        :ok
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :exec, fn _h, _cmd, args, _opts ->
        send(test, {:exec, args})
        {:ok, "", 0}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :clone_repositories, fn _h,
                                                                              _e,
                                                                              secrets,
                                                                              sprite_env,
                                                                              _c ->
        send(test, {:clone, secrets, sprite_env})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # The broker got the value; only the catalog key, not the rest.
      assert_receive {:prepared, conv_id, %{"GITHUB_TOKEN" => "ghp_real"} = brokered}, 2_000
      assert conv_id == conv.id
      refute Map.has_key?(brokered, "DATABASE_URL")

      # The process env: placeholder, proxy with the token, CA path.
      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)
      assert {"GITHUB_TOKEN", "__github_token__"} in spawn_env
      assert {"DATABASE_URL", "postgres://x"} in spawn_env
      assert {"HTTPS_PROXY", "http://av_sess_conv:c-test@broker.test:14322"} in spawn_env
      assert {"NODE_EXTRA_CA_CERTS", Fountain.Broker.ca_path()} in spawn_env
      refute Enum.any?(spawn_env, fn {_, v} -> v == "ghp_real" end)

      # The disk env: placeholder yes, proxy address (and its token) no.
      assert_receive {:env_file, file_env}, 2_000
      assert {"GITHUB_TOKEN", "__github_token__"} in file_env
      refute Enum.any?(file_env, fn {k, _} -> k in Fountain.Broker.process_only_keys() end)
      refute Enum.any?(file_env, fn {_, v} -> String.contains?(v, "av_sess_conv") end)

      # The floor: the broker's host, and nothing else, whatever the env said.
      assert_receive {:policy, %Fountain.Sandbox.NetworkPolicy{allow: ["broker.test"]}}, 2_000

      # The CA, in the OS trust store.
      assert_receive {:wrote, "/tmp/fountain-broker-ca.crt", "PEM"}, 2_000
      assert_receive {:exec, ["-lc", "sudo install -D -m 644 " <> _]}, 2_000

      # The clone sees the placeholder and the proxy, so git goes through the
      # broker and the broker rewrites the auth header.
      assert_receive {:clone, %{"GITHUB_TOKEN" => "__github_token__"}, clone_env}, 2_000
      assert {"HTTPS_PROXY", "http://av_sess_conv:c-test@broker.test:14322"} in clone_env

      assert Enum.map(stage_events(conv.id, "broker"), & &1.state) == ["started", "done"]
    end

    test "an unreachable broker fails the conversation before any sandbox is created", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()

      stub(Fountain.Broker, :preflight, fn -> {:error, {:broker, :unreachable, :listener_down}} end)

      reject(Fountain.Sandbox.Sprites, :create, 2)
      reject(Fountain.Broker, :prepare, 4)

      {_pid, _mon, :stopped} = start_server(conv)

      assert [event] = stage_events(conv.id, "broker")
      assert event.state == "failed"
      assert %{"reason" => "broker_unreachable"} = Jason.decode!(event.data)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a limited environment is refused before any sandbox is created", %{
      user: user
    } do
      env = insert_env(user_id: user.id, networking_type: "limited")
      agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      reject(Fountain.Broker, :preflight, 0)
      reject(Fountain.Sandbox.Sprites, :create, 2)

      {_pid, _mon, :stopped} = start_server(conv)

      assert [event] = stage_events(conv.id, "broker")
      assert %{"reason" => "limited_environment_unsupported"} = Jason.decode!(event.data)
    end

    test "a failed session mint tears the sandbox down and releases the vault", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      stub(Fountain.Broker, :preflight, fn -> :ok end)

      stub(Fountain.Broker, :prepare, fn _c, _u, _b, _bindings ->
        {:error, {:broker, :session, :timeout}}
      end)

      stub(Fountain.Broker, :release, fn conv_id ->
        send(test, {:released, conv_id})
        :ok
      end)

      Mimic.stub(Fountain.Sandbox.Sprites, :destroy, fn _h ->
        send(test, :destroyed)
        :ok
      end)

      {_pid, _mon, :stopped} = start_server(conv)

      assert_receive :destroyed, 2_000
      assert_receive {:released, conv_id}, 2_000
      assert conv_id == conv.id
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "terminating the conversation releases the vault", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      stub(Fountain.Broker, :prepare, fn _c, _u, _b, _bindings -> {:ok, @session} end)

      stub(Fountain.Broker, :release, fn conv_id ->
        send(test, {:released, conv_id})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      assert_receive {:spawned, _, _, _}, 2_000

      # The harness starts servers outside Horde, so the registry lookup the
      # public API does would miss it; the call is the same one it makes.
      :ok = GenServer.call(pid, :terminate_conv)

      assert_receive {:released, conv_id}, 2_000
      assert conv_id == conv.id
    end
  end
end
