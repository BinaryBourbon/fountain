defmodule Fountain.Conversations.OutputTest do
  @moduledoc """
  What the sandbox says on its way to the transcript (#1377), driven without
  a server: the durable budget (#331) and its one marker, the reattach replay
  skip, the two broadcasts and the stage door.

  The budget is exercised against the real default rather than by writing
  `:log_output_byte_budget`: the value is global, this file is async, and a
  value already loaded into an `%Output{}` reaches the same branch.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Output
  alias Managoat.Sandbox.Handle

  @budget 50_000_000

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    turn = insert_turn(conv, status: "running")

    ctx = %{conversation_id: conv.id, turn_id: turn.id, user_id: user.id}
    {:ok, user: user, conv: conv, turn: turn, ctx: ctx}
  end

  defp outputs(conv_id) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "output",
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.stream, &1.data, &1.stage, &1.turn_id})
  end

  describe "the server boundary" do
    test "from_state/1 and into_state/2 round-trip the three fields" do
      state = %{output_bytes: 7, output_capped: false, replay_skip: %{"stdout" => 3}, other: 1}

      assert %Output{bytes: 7, capped: false, replay_skip: %{"stdout" => 3}} =
               out = Output.from_state(state)

      assert Output.into_state(state, %{out | capped: true}) == %{state | output_capped: true}
    end

    test "ctx/1 reads the conversation, the turn in flight and the owner", %{
      conv: conv,
      turn: turn,
      user: user
    } do
      state = %{conversation_id: conv.id, current_turn: turn, user_id: user.id}
      assert Output.ctx(state) == %{conversation_id: conv.id, turn_id: turn.id, user_id: user.id}
    end

    test "ctx/1 has no turn id between turns", %{conv: conv, user: user} do
      state = %{conversation_id: conv.id, current_turn: nil, user_id: user.id}
      assert %{turn_id: nil} = Output.ctx(state)
    end
  end

  describe "log/4" do
    test "persists the chunk against the turn and counts its bytes", %{ctx: ctx, turn: turn} do
      assert %Output{bytes: 5, capped: false} =
               Output.log(%Output{bytes: 0}, ctx, "stdout", "hello")

      assert [{"stdout", "hello", "turn", turn_id}] = outputs(ctx.conversation_id)
      assert turn_id == turn.id
    end

    test "broadcasts the event and moves the owner's sidebar", %{ctx: ctx, user: user} do
      Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{ctx.conversation_id}")
      Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user.id}")

      Output.log(%Output{bytes: 0}, ctx, "stdout", "hi")

      assert_receive {:log_event, %Conversations.LogEvent{data: "hi"}}
      assert_receive {:sidebar_update, sidebar_user}
      assert sidebar_user == user.id
    end

    test "loads the conversation's byte total on the first chunk", %{ctx: ctx} do
      Output.persist(ctx, "stdout", "already persisted")

      # `bytes: nil` is a server that has just woken: the budget is cumulative
      # per conversation across wakes, not per BEAM lifetime.
      assert %Output{bytes: bytes} = Output.log(%Output{}, ctx, "stdout", "ab")
      assert bytes == byte_size("already persisted") + 2
    end

    test "caps once at the budget and drops every later chunk", %{ctx: ctx} do
      over = %Output{bytes: @budget}

      assert %Output{capped: true} = capped = Output.log(over, ctx, "stdout", "one more byte")

      assert [{"stderr", marker, _, _}] = outputs(ctx.conversation_id)
      assert marker == Output.cap_marker(@budget)

      assert ^capped = Output.log(capped, ctx, "stdout", "and another")
      assert length(outputs(ctx.conversation_id)) == 1
    end

    test "the cap emits the telemetry the operator watches", %{ctx: ctx} do
      :telemetry.attach(
        "output-test-cap",
        [:fountain, :log_output, :capped],
        fn _event, measurements, meta, pid -> send(pid, {:capped, measurements, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach("output-test-cap") end)

      Output.log(%Output{bytes: @budget}, ctx, "stdout", "over")

      assert_receive {:capped, %{count: 1}, %{conversation_id: conv_id}}
      assert conv_id == ctx.conversation_id
    end
  end

  describe "cap_marker/1 and byte_budget/0" do
    test "the marker names the budget in megabytes" do
      assert Output.cap_marker(@budget) =~ "durable log budget of 50 MB"
    end

    test "the default budget is 50 MB" do
      assert Output.byte_budget() == @budget
    end
  end

  describe "log_with_replay_skip/4" do
    test "logs everything when nothing is being replayed", %{ctx: ctx} do
      assert %Output{bytes: 2, replay_skip: %{}} =
               Output.log_with_replay_skip(%Output{bytes: 0}, ctx, "stdout", "ab")

      assert [{"stdout", "ab", _, _}] = outputs(ctx.conversation_id)
    end

    test "drops a chunk wholly inside the replayed tail", %{ctx: ctx} do
      out = %Output{bytes: 0, replay_skip: %{"stdout" => 5}}

      assert %Output{bytes: 0, replay_skip: %{"stdout" => 2}} =
               Output.log_with_replay_skip(out, ctx, "stdout", "abc")

      assert outputs(ctx.conversation_id) == []
    end

    test "logs the remainder of the chunk the replay ends inside", %{ctx: ctx} do
      out = %Output{bytes: 0, replay_skip: %{"stdout" => 2}}

      assert %Output{bytes: 3, replay_skip: %{"stdout" => 0}} =
               Output.log_with_replay_skip(out, ctx, "stdout", "abcde")

      assert [{"stdout", "cde", _, _}] = outputs(ctx.conversation_id)
    end

    test "the skip is per stream", %{ctx: ctx} do
      out = %Output{bytes: 0, replay_skip: %{"stdout" => 5}}

      assert %Output{bytes: 2} = Output.log_with_replay_skip(out, ctx, "stderr", "ab")
      assert [{"stderr", "ab", _, _}] = outputs(ctx.conversation_id)
    end
  end

  describe "publish_stage/4" do
    test "puts a stage row on the same transcript", %{conv: conv} do
      Output.publish_stage(conv.id, "turn", "started", %{turn_number: 1})

      assert [event] =
               Fountain.Repo.all(
                 from(e in Conversations.LogEvent,
                   where: e.conversation_id == ^conv.id and e.kind == "stage"
                 )
               )

      assert event.stage == "turn"
      assert event.state == "started"
      assert Jason.decode!(event.data) == %{"turn_number" => 1}
    end
  end

  describe "write_image_temp_files/3" do
    test "writes nothing for no images" do
      assert Output.write_image_temp_files(%Handle{provider: :sprites, name: "s"}, "t1", []) == []
    end

    test "writes each image and returns its path and media type" do
      test = self()

      Mimic.stub(Managoat.Sandbox, :write_file, fn _handle, path, data ->
        send(test, {:wrote, path, data})
        :ok
      end)

      images = [
        %{media_type: "image/png", data: "one"},
        %{media_type: "image/tiff", data: "two"}
      ]

      assert [{png, "image/png"}, {bin, "image/tiff"}] =
               Output.write_image_temp_files(%Handle{provider: :sprites, name: "s"}, "t1", images)

      # The extension comes from the media type, and an unknown one is `.bin`
      # rather than a guess the runtime would refuse to open.
      assert png == "/tmp/aod_turn_t1_0.png"
      assert bin == "/tmp/aod_turn_t1_1.bin"

      assert_receive {:wrote, "/tmp/aod_turn_t1_0.png", "one"}
      assert_receive {:wrote, "/tmp/aod_turn_t1_1.bin", "two"}
    end
  end
end
