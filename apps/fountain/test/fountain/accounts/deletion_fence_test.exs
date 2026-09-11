defmodule Fountain.Accounts.DeletionFenceTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.{Audit, Conversations, Principals}
  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    stub(ConversationServer, :whereis, fn _ -> nil end)
    %{user: user, sandbox: sandbox, conv: conv}
  end

  for capacity <- [1, :unbounded] do
    test "account deletion fences #{inspect(capacity)} admission before provider deletion", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ ->
        refute Repo.in_transaction?()
        assert Repo.reload!(ctx.sandbox).reset_requested_at
        assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 1
        assert {:error, :sandbox_unavailable} = admit(ctx, unquote(capacity))
        assert [event] = events(ctx.user.id)
        assert event.actor == "ui"
        assert event.request_ip == "192.0.2.1"
        assert event.metadata["reason"] == "account_deleted"
        :ok
      end)

      assert {:ok, %{sprites_destroyed: 1}} =
               Deletion.delete_user(ctx.user, actor: "ui", request_ip: "192.0.2.1")

      refute Repo.get(User, ctx.user.id)
      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end
  end

  test "all known machines are fenced before the first actor is stopped", ctx do
    other = insert_sandbox(user_id: ctx.user.id, status: "ready")
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(ConversationServer, :terminate_conversation, fn id, _ ->
      # Cleanup catches actor failures, so assert this snapshot after it returns.
      send(
        self(),
        {:actor_boundary, id, Repo.in_transaction?(),
         Repo.reload!(ctx.sandbox).reset_requested_at, Repo.reload!(other).reset_requested_at}
      )

      :ok
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, 2, fn _ -> :ok end)
    assert Deletion.destroy_sprites(ctx.user) == 2
    assert_received {:actor_boundary, id, false, %DateTime{}, %DateTime{}}
    assert id == ctx.conv.id
    assert length(events(ctx.user.id)) == 2
  end

  test "a machine found after actor shutdown is also fenced before provider deletion", ctx do
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(ConversationServer, :terminate_conversation, fn _, _ ->
      late = insert_sandbox(user_id: ctx.user.id, status: "ready")
      send(self(), {:late_sandbox, late.id})
      :ok
    end)

    expect(Managoat.Sandbox.Sprites, :destroy, 2, fn handle ->
      sandbox = Repo.get_by!(Conversations.Sandbox, sprite_name: handle.name)
      refute Repo.in_transaction?()
      assert sandbox.reset_requested_at
      :ok
    end)

    assert Deletion.destroy_sprites(ctx.user.id) == 2
    assert_received {:late_sandbox, late_id}
    assert Repo.get!(Conversations.Sandbox, late_id).status == "terminated"
    assert length(events(ctx.user.id)) == 2
  end

  test "a refused fence retains the account and stops before actor or provider work", ctx do
    expect(Conversations, :_unsafe_fence_sandbox_for_teardown, fn _, _ ->
      {:error, :fixture_refusal}
    end)

    reject(ConversationServer, :terminate_conversation, 2)
    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert {:error, :fixture_refusal} = Deletion.delete_user(ctx.user)
    assert Repo.get(User, ctx.user.id)
    assert Repo.reload!(ctx.sandbox).status == "ready"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
    assert events(ctx.user.id) == []
    assert Audit.list_for_user(ctx.user.id, action_prefix: "account.deleted") == []
  end

  test "principal cleanup forwards the closing caller's attribution", ctx do
    assert {:ok, %{claimable: claimable}} =
             Principals.create_claimable(ctx.user, %{"application_id" => "fence-test"})

    sandbox = insert_sandbox(user_id: claimable.user_id, status: "ready")

    expect(Managoat.Sandbox.Sprites, :destroy, fn _ ->
      assert Repo.reload!(sandbox).reset_requested_at
      refute Repo.in_transaction?()
      :ok
    end)

    assert {:ok, _} =
             Principals.release(claimable,
               actor: "system:principal_sweep",
               request_ip: "192.0.2.2"
             )

    assert [event] = events(claimable.user_id)
    assert event.actor == "system:principal_sweep"
    assert event.request_ip == "192.0.2.2"
    assert event.metadata["reason"] == "principal_closed"
    assert Repo.reload!(sandbox).status == "terminated"
    refute Repo.reload!(ctx.sandbox).reset_requested_at
  end

  test "provider failure still retires the fenced row and counts no confirmed deletion", ctx do
    expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)
    assert Deletion.destroy_sprites(ctx.user) == 0
    assert Repo.reload!(ctx.sandbox).status == "terminated"
    assert Repo.reload!(ctx.sandbox).reset_requested_at
    assert Fountain.Quotas.active_sandbox_count(ctx.user.id) == 0
  end

  test "an actor-retired machine is not destroyed or counted again", ctx do
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(ConversationServer, :terminate_conversation, fn _, _ ->
      {:ok, _} = Conversations.update_sandbox(ctx.sandbox, %{status: "terminated"})
      :ok
    end)

    reject(Managoat.Sandbox.Sprites, :destroy, 1)
    assert Deletion.destroy_sprites(ctx.user) == 0
    assert [_] = events(ctx.user.id)
  end

  test "refusing a newly discovered machine's fence retains the account", ctx do
    stub(ConversationServer, :whereis, fn _ -> self() end)

    expect(ConversationServer, :terminate_conversation, fn _, _ ->
      late = insert_sandbox(user_id: ctx.user.id, status: "ready")
      send(self(), {:late_sandbox, late.id})
      :ok
    end)

    stub(Conversations, :_unsafe_fence_sandbox_for_teardown, fn sandbox, opts ->
      if sandbox.id == ctx.sandbox.id do
        Mimic.call_original(Conversations, :_unsafe_fence_sandbox_for_teardown, [sandbox, opts])
      else
        {:error, :late_fence_refused}
      end
    end)

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(self(), {:destroyed, handle.name})
      :ok
    end)

    assert {:error, :late_fence_refused} = Deletion.delete_user(ctx.user)
    assert_received {:late_sandbox, late_id}
    late = Repo.get!(Conversations.Sandbox, late_id)
    late_name = late.sprite_name
    refute_received {:destroyed, ^late_name}
    refute late.reset_requested_at
    assert late.status == "ready"
    assert Repo.get(User, ctx.user.id)
    assert Audit.list_for_user(ctx.user.id, action_prefix: "account.deleted") == []
  end

  defp admit(ctx, capacity) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{conversation_id: ctx.conv.id, turn_number: 1, status: "running", prompt: "late"},
      ctx.sandbox.id,
      capacity
    )
  end

  defp events(user_id),
    do: Audit.list_for_user(user_id, action_prefix: "sandbox.teardown_requested")
end
