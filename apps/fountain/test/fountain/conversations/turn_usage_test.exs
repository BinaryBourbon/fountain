defmodule Fountain.Conversations.TurnUsageTest do
  @moduledoc "`Conversations._unsafe_record_turn_usage/2` (#827): once per turn, summed on the conversation."
  use Fountain.DataCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    {:ok, user: user, conv: conv}
  end

  test "stamps the turn and adds to the conversation's running sums", %{conv: conv} do
    t1 = insert_turn(conv, prompt: "one", status: "completed")
    t2 = insert_turn(conv, prompt: "two", status: "completed", turn_number: 2)

    assert {:ok, %{usage: %{"input" => 100, "output" => 20}}} =
             Conversations._unsafe_record_turn_usage(t1, %{"input" => 100, "output" => 20})

    assert {:ok, _} =
             Conversations._unsafe_record_turn_usage(t2, %{
               "input" => 50,
               "output" => 5,
               "cache_read" => 40
             })

    conv = Conversations._unsafe_get_conversation!(conv.id)
    assert conv.usage_input_tokens == 150
    assert conv.usage_output_tokens == 25

    assert Conversations._unsafe_list_turns(conv.id) |> Enum.map(& &1.usage) == [
             %{"input" => 100, "output" => 20},
             %{"input" => 50, "output" => 5, "cache_read" => 40}
           ]
  end

  test "nil records nothing; a second figure for the same turn is refused", %{conv: conv} do
    t = insert_turn(conv, prompt: "one", status: "completed")
    assert :ok = Conversations._unsafe_record_turn_usage(t, nil)
    assert {:ok, t} = Conversations._unsafe_record_turn_usage(t, %{"input" => 1, "output" => 1})

    assert {:error, :already_recorded} =
             Conversations._unsafe_record_turn_usage(t, %{"input" => 1, "output" => 1})

    assert %{usage_input_tokens: 1, usage_output_tokens: 1} =
             Conversations._unsafe_get_conversation!(conv.id)
  end
end
