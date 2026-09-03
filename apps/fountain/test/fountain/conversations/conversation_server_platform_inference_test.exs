defmodule Fountain.Conversations.ConversationServerPlatformInferenceTest do
  # The platform key through a real ConversationServer (#1388): that it is
  # selected only when the tenant has none, that it takes the *same* two
  # routes a tenant's own key takes (ADR 0019 gate 3 when brokered, the
  # sandbox env when not), and that the turn it ran is marked so the pricer
  # can find it.
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.TurnMachine

  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}
  @platform_key "sk-ant-platform-key"

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude", model: "anthropic/claude-opus-5")

    previous =
      for key <- [
            :broker_listen_port,
            :broker_proxy_url,
            :broker_tenants,
            :platform_anthropic_api_key
          ],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    # The deployment holds a key. The tenant holds nothing — that is
    # `ConversationServerCase`'s own default stub of `decrypted_for_user/2`,
    # which the two tests about a tenant's own key override.
    Application.put_env(:fountain, :platform_anthropic_api_key, @platform_key)

    {:ok, user: user, agent: agent}
  end

  describe "the non-brokered path" do
    test "the platform key is what the runtime is handed, exactly as a tenant's own is", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      reject(Fountain.Broker, :prepare, 4)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # The harness runtime ignores credentials, so the assertion is on what
      # the server hands `default_env/2` plus what the real runtime makes of
      # it — the same two halves the broker test checks.
      state = :sys.get_state(pid)
      assert state.env_credentials == %{anthropic_api_key: @platform_key}
      assert state.brokered == %{}

      assert Managoat.Runtimes.Claude.default_env(nil, state.env_credentials) ==
               [{"ANTHROPIC_API_KEY", @platform_key}]
    end

    test "a tenant with their own key never sees the platform one", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      # After `stub_happy_sprite/0`, which sets the case's own default of "no
      # credentials at all" — a stub set before it is overwritten by it.
      Mimic.stub(Fountain.InferenceCredentials, :decrypted_for_user, fn _u, _k ->
        {:ok, %{anthropic_api_key: "sk-ant-tenant-key"}}
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      assert state.inference_source == :own
      assert state.env_credentials == %{anthropic_api_key: "sk-ant-tenant-key"}
    end
  end

  describe "the brokered path (ADR 0019 gate 3)" do
    setup %{user: user} do
      Application.put_env(:fountain, :broker_listen_port, 14_322)
      Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
      Application.put_env(:fountain, :broker_tenants, [user.id])
      :ok
    end

    test "the platform key goes to the broker and never into the sandbox", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn _c, brokered, bindings, _opts ->
        send(test, {:prepared, brokered, bindings})
        {:ok, @session}
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # Same route as a tenant's own key: the value reaches the broker with
      # an implicit substitute binding to the provider's host.
      assert_receive {:prepared, brokered, bindings}, 2_000
      assert brokered["ANTHROPIC_API_KEY"] == @platform_key

      assert [%{host: "api.anthropic.com", auth_type: "substitute"}] =
               bindings["ANTHROPIC_API_KEY"]

      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)
      refute Enum.any?(spawn_env, fn {_, v} -> v == @platform_key end)
    end
  end

  describe "the mark on the turn" do
    test "the server records which key it selected", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      {pid, _mon, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      state = :sys.get_state(pid)
      assert state.inference_source == :platform
      assert state.inference_model == "anthropic/claude-opus-5"
      assert state.env_credentials.anthropic_api_key == @platform_key
    end

    test "usage says which key ran the turn, and names the model on a platform turn" do
      ctx = %{inference: :platform, model: "anthropic/claude-opus-5"}

      assert TurnMachine.with_inference(%{"input" => 5, "output" => 3}, ctx) ==
               %{
                 "input" => 5,
                 "output" => 3,
                 "inference" => "platform",
                 "model" => "anthropic/claude-opus-5"
               }

      assert TurnMachine.with_inference(%{"input" => 5}, %{ctx | inference: :own}) ==
               %{"input" => 5, "inference" => "own"}

      assert TurnMachine.with_inference(nil, ctx) == nil
    end

    test "with no platform key configured the usage map is untouched" do
      Application.delete_env(:fountain, :platform_anthropic_api_key)

      ctx = %{inference: :own, model: "anthropic/claude-opus-5"}
      assert TurnMachine.with_inference(%{"input" => 5}, ctx) == %{"input" => 5}
    end
  end

  defp stub_turn_boundary do
    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
    ref
  end
end
