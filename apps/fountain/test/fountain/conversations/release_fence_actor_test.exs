defmodule Fountain.Conversations.ReleaseFenceActorTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.ExecutionGuard

  test "an idle actor refuses unresolved remote work before closing anything" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    stub_happy_sprite(sandbox.sprite_name)
    {pid, _monitor, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    turn = insert_turn(conv, status: "running")

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    {:ok, _} = ExecutionGuard._unsafe_claim_spawn(execution.id)
    {:ok, _} = ExecutionGuard._unsafe_interrupt(conv.id)
    before = :sys.get_state(pid)
    assert is_nil(before.current_turn)
    parent = Conversations._unsafe_get_conversation!(conv.id)
    key = Repo.get!(Fountain.Accounts.ApiKey, parent.callback_api_key_id)
    events = Conversations._unsafe_list_log_events(conv.id)

    assert {:error, :busy} = GenServer.call(pid, :release_conv)
    assert :sys.get_state(pid) == before
    assert Conversations._unsafe_get_conversation!(conv.id) == parent
    assert Repo.reload!(key) == key
    assert Conversations._unsafe_list_log_events(conv.id) == events
    assert ExecutionGuard._unsafe_for_turn(turn.id).state == "awaiting_identity"
    assert Repo.reload!(sandbox).status == "ready"
  end
end
