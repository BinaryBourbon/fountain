defmodule Fountain.Conversations.StreamFilterTest do
  @moduledoc """
  `?streams=` has two implementations and they must agree.

  One filters a query (history, `_unsafe_list_log_events/3`); the other filters
  an event already in hand (live, over PubSub). They disagreed for as long as
  the `acp` stream existed: the query half carried an allow-list of
  `["stdout", "stderr"]` written before ACP, so a filtered request answered
  with a conversation's future and none of its past.

  Nothing caught it because each half was plausible on its own, and the two
  are only comparable when you run one table through both — which is what this
  file does.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id)
    {:ok, conv: conv}
  end

  describe "history and live agree" do
    test "for every stream name we store", %{conv: conv} do
      events = %{
        "acp" => insert_log_event(conv, %{stream: "acp", data: ~s({"method":"session/update"})}),
        "stdout" => insert_log_event(conv, %{stream: "stdout"}),
        "stderr" => insert_log_event(conv, %{stream: "stderr"}),
        "stage" =>
          insert_log_event(conv, %{kind: "stage", stream: "", stage: "turn", state: "done"})
      }

      selections = [
        ["acp"],
        ["stage"],
        ["acp", "stage"],
        ["stdout", "stderr"],
        ["acp", "stdout", "stderr", "stage"],
        ["nonsense"],
        nil
      ]

      for streams <- selections, {name, event} <- events do
        from_history =
          conv.id
          |> Conversations._unsafe_list_log_events(0, streams: streams)
          |> Enum.any?(&(&1.id == event.id))

        from_live = Conversations.event_in_streams?(event, streams)

        assert from_history == from_live,
               "#{name} event: history says #{from_history}, live says #{from_live} " <>
                 "for streams=#{inspect(streams)}"
      end
    end
  end

  describe "the acp stream" do
    # The regression. `session/load` replays a conversation by asking for
    # exactly this, so an empty answer means an editor reopens to a blank
    # transcript for a conversation that has one (#703).
    test "is replayed when asked for by name", %{conv: conv} do
      acp = insert_log_event(conv, %{stream: "acp", data: ~s({"method":"session/update"})})
      insert_log_event(conv, %{stream: "stdout"})

      ids =
        conv.id
        |> Conversations._unsafe_list_log_events(0, streams: ["acp"])
        |> Enum.map(& &1.id)

      assert ids == [acp.id]
    end

    # What a reconnect mid-turn asks for: the updates it missed, plus the
    # stage event that ends the turn. Dropping the `acp` half loses exactly
    # the output produced while the connection was down.
    test "is replayed alongside stage events", %{conv: conv} do
      acp = insert_log_event(conv, %{stream: "acp"})
      stage = insert_log_event(conv, %{kind: "stage", stream: "", stage: "turn", state: "done"})
      insert_log_event(conv, %{stream: "stdout"})

      ids =
        conv.id
        |> Conversations._unsafe_list_log_events(0, streams: ["acp", "stage"])
        |> Enum.map(& &1.id)

      assert ids == [acp.id, stage.id]
    end
  end

  describe "unknown names" do
    # No allow-list any more, so this holds by construction rather than by a
    # list someone has to remember to extend: a name no row carries matches no
    # row.
    test "match nothing rather than everything", %{conv: conv} do
      insert_log_event(conv, %{stream: "acp"})
      insert_log_event(conv, %{stream: "stdout"})

      assert Conversations._unsafe_list_log_events(conv.id, 0, streams: ["not-a-stream"]) == []
    end

    test "do not suppress the names alongside them", %{conv: conv} do
      acp = insert_log_event(conv, %{stream: "acp"})

      ids =
        conv.id
        |> Conversations._unsafe_list_log_events(0, streams: ["not-a-stream", "acp"])
        |> Enum.map(& &1.id)

      assert ids == [acp.id]
    end
  end

  describe "no filter" do
    test "returns everything", %{conv: conv} do
      for stream <- ~w(acp stdout stderr), do: insert_log_event(conv, %{stream: stream})

      assert length(Conversations._unsafe_list_log_events(conv.id, 0, streams: nil)) == 3
      assert length(Conversations._unsafe_list_log_events(conv.id, 0, streams: [])) == 3
    end
  end
end
