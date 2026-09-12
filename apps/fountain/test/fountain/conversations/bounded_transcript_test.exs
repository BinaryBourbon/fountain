defmodule Fountain.Conversations.BoundedTranscriptTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Conversations.{ExecutionGuard, LogEvent, Output, Turn, TurnExecution}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    turn = insert_turn(conv, status: "running")

    {:ok, execution} =
      ExecutionGuard._unsafe_register(
        turn.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
    Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

    %{
      conv: conv,
      turn: turn,
      execution: execution,
      sandbox: sandbox,
      ctx: %{conversation_id: conv.id, turn_id: turn.id, user_id: user.id}
    }
  end

  defp output(c, text), do: Output.persist(c.ctx, "stdout", text)
  defp rows(c), do: Repo.all(from e in LogEvent, where: e.conversation_id == ^c.conv.id)

  test "active output and stages retain the exact turn and broadcast after commit", c do
    assert :ok = output(c, "before cancellation")
    assert_receive {:log_event, %{kind: "output", turn_id: id}}
    assert id == c.turn.id
    assert_receive {:sidebar_update, _}
    event = Conversations.publish_stage(c.conv.id, "model", "done", %{"turn_id" => c.turn.id})
    assert event.turn_id == c.turn.id
    assert_receive {:log_event, ^event}
    assert length(rows(c)) == 2
  end

  test "retirement drops output and model stages without broadcasting nil or moving the sidebar",
       c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    assert :ok = output(c, "late reply")
    assert nil == Conversations.publish_stage(c.conv.id, "model", "done", %{turn_id: c.turn.id})
    assert rows(c) == []
    refute_received {:log_event, _}
    refute_received {:sidebar_update, _}
  end

  test "an elapsed deadline is enforced by the writer without a coordinator tick", c do
    c.execution
    |> Ecto.Changeset.change(deadline_at: DateTime.add(DateTime.utc_now(), -1))
    |> Repo.update!()

    assert :ok = output(c, "too late")
    assert [%{kind: "stage", state: "failed", turn_id: id}] = rows(c)
    assert id == c.turn.id
    assert Repo.get!(Turn, id).limit_reason == "wall_time_limit"
    refute_received {:log_event, _}
    refute_received {:sidebar_update, _}
  end

  test "a wrong conversation cannot relabel another bounded turn's output or terminal event", c do
    other = insert_conversation(user_id: insert_verified_user().id)
    ctx = %{c.ctx | conversation_id: other.id}
    assert :ok = Output.persist(ctx, "stdout", "crossed")
    assert nil == Conversations.publish_stage(other.id, "turn", "done", %{turn_id: c.turn.id})
    assert Repo.aggregate(LogEvent, :count) == 0
    assert Repo.get!(TurnExecution, c.execution.id).state == "active"
  end

  test "changed sandbox identity refuses transcript writes", c do
    c.sandbox |> Ecto.Changeset.change(sprite_name: "replacement") |> Repo.update!()
    assert :ok = output(c, "old machine")
    assert rows(c) == []
  end

  test "deleted parents cannot acquire late output", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    Repo.delete!(c.conv)
    assert :ok = output(c, "orphaned output")
    assert rows(c) == []
  end

  test "stale turn mutations cannot change the retired revision or its decision", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    original = Repo.get!(Turn, c.turn.id)

    {:ok, result} =
      Conversations._unsafe_update_turn(c.turn, %{
        status: "completed",
        exit_code: 0,
        prompt: "replacement prompt",
        reply_text: "late answer",
        model_selection: %{status: "selected"},
        pending_permission: %{id: "late"},
        acp_prompt_id: 99,
        usage: %{"input" => 999},
        turn_number: 9
      })

    assert result == original
  end

  test "a cancellation cannot acquire a contradictory completion stage", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    assert nil == Conversations.publish_stage(c.conv.id, "turn", "done", %{turn_id: c.turn.id})

    assert %{state: "interrupted"} =
             Conversations.publish_stage(c.conv.id, "turn", "interrupted", %{turn_id: c.turn.id})

    assert [%{state: "interrupted"}] = rows(c)
  end

  test "late old output cannot contaminate a successor on the same conversation", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    successor = insert_turn(c.conv, status: "running")

    {:ok, _} =
      ExecutionGuard._unsafe_register(
        successor.id,
        Ecto.UUID.generate(),
        DateTime.add(DateTime.utc_now(), 60)
      )

    assert :ok = output(c, "old output")
    assert :ok = Output.persist(%{c.ctx | turn_id: successor.id}, "stdout", "new output")
    assert [%{data: "new output", turn_id: id}] = rows(c)
    assert id == successor.id
  end

  test "delayed usage remains recordable after retirement and stale duplicates count once", c do
    {:ok, _} = ExecutionGuard._unsafe_interrupt(c.conv.id)
    usage = %{"input" => 7, "output" => 3, "accounting" => %{"complete" => false}}

    assert {:ok, %{usage: ^usage, status: "interrupted"}} =
             Conversations._unsafe_record_turn_usage(c.turn, usage)

    assert {:error, :already_recorded} =
             Conversations._unsafe_record_turn_usage(c.turn, %{"input" => 99})

    conv = Conversations._unsafe_get_conversation!(c.conv.id)
    assert conv.usage_input_tokens == 7
    assert conv.usage_output_tokens == 3
    assert Repo.get!(Turn, c.turn.id).usage == usage
  end

  test "usage refuses a stale parent binding without charging its counters", c do
    other = insert_conversation(user_id: insert_verified_user().id)

    assert {:error, :not_found} =
             Conversations._unsafe_record_turn_usage(%{c.turn | conversation_id: other.id}, %{
               "input" => 99
             })

    assert Conversations._unsafe_get_conversation!(other.id).usage_input_tokens == 0
    assert Repo.get!(Turn, c.turn.id).usage == nil
  end

  test "deleted turns refuse delayed usage without a stale-entry crash", c do
    Repo.delete!(c.turn)

    assert {:error, :not_found} =
             Conversations._unsafe_record_turn_usage(c.turn, %{"input" => 99})
  end

  describe "the unbounded path" do
    test "an unbounded turn's output is published unchanged, in the same shape", c do
      # The fence can only suppress; it never rewrites. So an unbounded turn's
      # transcript is byte-for-byte what it was, which matters because the two
      # apps that read it live outside this repo (ADR 0034) and nothing here
      # can update them in lockstep.
      plain_conv =
        insert_conversation(user_id: c.ctx.user_id, sandbox: c.sandbox, status: "running")

      plain_turn = insert_turn(plain_conv, status: "running")
      refute ExecutionGuard._unsafe_for_turn(plain_turn.id)

      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{plain_conv.id}")

      assert :ok =
               Output.persist(
                 %{
                   conversation_id: plain_conv.id,
                   turn_id: plain_turn.id,
                   user_id: c.ctx.user_id
                 },
                 "stdout",
                 "hello"
               )

      assert_receive {:log_event, %LogEvent{} = event}
      assert event.conversation_id == plain_conv.id
      assert event.turn_id == plain_turn.id
      assert event.kind == "output"
      assert event.stream == "stdout"
      assert event.data == "hello"
      assert is_integer(event.id)
      assert_receive {:sidebar_update, _}
    end

    test "a duplicate usage delivery is refused rather than overwriting, bounded or not", c do
      plain_conv =
        insert_conversation(user_id: c.ctx.user_id, sandbox: c.sandbox, status: "running")

      plain_turn = insert_turn(plain_conv, status: "running")

      assert {:ok, _} =
               Conversations._unsafe_record_turn_usage(plain_turn, %{"input" => 5, "output" => 7})

      # The dedup reaches the unbounded path too: a retried provider delivery
      # used to overwrite and double-count the conversation's counters.
      assert {:error, :already_recorded} =
               Conversations._unsafe_record_turn_usage(plain_turn, %{
                 "input" => 500,
                 "output" => 700
               })

      assert Repo.get!(Turn, plain_turn.id).usage == %{"input" => 5, "output" => 7}
      reloaded = Conversations._unsafe_get_conversation!(plain_conv.id)
      assert reloaded.usage_input_tokens == 5
      assert reloaded.usage_output_tokens == 7
    end
  end
end
