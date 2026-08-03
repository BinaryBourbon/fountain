defmodule Fountain.Conversations.ConversationServerLogBudgetTest do
  # #331: log_events had no per-conversation volume bound inside the
  # retention window — retention bounds age, not rate, and Postgres is the
  # same volume the app depends on. Once the budget is exceeded, one
  # truncation marker is persisted and later chunks are dropped.
  use Fountain.ConversationServerCase

  setup do
    Application.put_env(:fountain, :log_output_byte_budget, 100)
    on_exit(fn -> Application.delete_env(:fountain, :log_output_byte_budget) end)
    :ok
  end

  defp start_with_turn(conv) do
    cmd_ref = make_ref()

    Mimic.stub(Sprites, :spawn, fn _s, _cmd, _args, _opts ->
      {:ok, %{ref: cmd_ref, pid: self()}}
    end)

    Mimic.stub(Sprites, :write, fn _cmd, _data -> :ok end)
    Mimic.stub(Sprites, :close_stdin, fn _cmd -> :ok end)

    {pid, mon, :alive} = start_server(conv, initial_prompt: "go")
    _ = :sys.get_state(pid)
    {pid, cmd_ref, mon}
  end

  defp setup_conv do
    stub_happy_sprite()
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    insert_conversation(user_id: user.id, agent_id: agent.id)
  end

  defp output_events(conv_id) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "output"))
  end

  test "output over the budget is replaced by a single marker and then dropped" do
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    # 3 x 60 bytes against a 100-byte budget: chunk 1 persists, chunk 2
    # crosses the budget → marker, chunk 3 is silently dropped.
    chunk = String.duplicate("a", 60)
    for _ <- 1..3, do: send(pid, {:stdout, %{ref: cmd_ref}, chunk})
    _ = :sys.get_state(pid)

    events = output_events(conv.id)
    data = Enum.map(events, & &1.data)

    assert Enum.count(data, &(&1 == chunk)) == 1
    assert [marker] = Enum.filter(data, &(&1 =~ "durable log budget"))
    assert marker =~ "discarded"

    # Nothing after the marker.
    assert length(events) == 2

    GenServer.stop(pid)
  end

  test "the budget seeds from bytes already persisted, so it is cumulative across wakes" do
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    send(pid, {:stdout, %{ref: cmd_ref}, String.duplicate("b", 90)})
    _ = :sys.get_state(pid)

    # The seed a fresh server for this conversation would start from: the
    # DB total, not zero — which is what makes the budget per-conversation
    # rather than per-BEAM-lifetime.
    assert Conversations._unsafe_output_byte_total(conv.id) == 90

    # And the in-flight counter agrees with the durable one.
    assert :sys.get_state(pid).output_bytes == 90
    GenServer.stop(pid)
  end

  test "a 0 budget disables the cap" do
    Application.put_env(:fountain, :log_output_byte_budget, 0)
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    for _ <- 1..5, do: send(pid, {:stdout, %{ref: cmd_ref}, String.duplicate("d", 60)})
    _ = :sys.get_state(pid)

    assert Enum.count(output_events(conv.id), &(&1.data =~ "dddd")) == 5
    GenServer.stop(pid)
  end

  test "under the budget, output persists exactly as before" do
    conv = setup_conv()
    {pid, cmd_ref, _ref} = start_with_turn(conv)

    send(pid, {:stdout, %{ref: cmd_ref}, "hello"})
    _ = :sys.get_state(pid)

    assert Enum.any?(output_events(conv.id), &(&1.data == "hello"))
    refute Enum.any?(output_events(conv.id), &(&1.data =~ "durable log budget"))
    GenServer.stop(pid)
  end
end
