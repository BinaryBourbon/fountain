defmodule FountainWeb.PromptReceiptControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations.{ConversationServer, PromptDelivery, Turn, TurnImage}
  alias Fountain.Repo

  setup do
    user = insert_verified_user()
    {_record, key} = insert_api_key(user)
    conv = insert_conversation(user_id: user.id, status: "idle")
    stub(ConversationServer, :whereis, fn _ -> self() end)
    %{user: user, key: key, conv: conv}
  end

  defp request(c, payload, key \\ "receipt-key") do
    c.conn
    |> authed_with_key(c.key)
    |> put_req_header("idempotency-key", key)
    |> post_json("/api/conversations/#{c.conv.id}/prompts", payload)
  end

  test "the actual prompt route persists text and images once and returns a stable receipt", c do
    bytes = <<0, 1, 2>>

    payload = %{
      "prompt" => "Review image",
      "images" => [
        %{"media_type" => "image/png", "data" => Base.encode64(bytes)}
      ]
    }

    first = request(c, payload) |> json_response(200)
    retry = request(c, payload) |> json_response(200)
    assert first == retry
    assert first["status"] == "queued"
    assert first["delivery_deadline_at"]
    assert Repo.get!(Turn, first["turn_id"]).prompt == "Review image"
    assert Repo.one!(TurnImage).data == bytes
    assert Repo.aggregate(Turn, :count) == 1
    assert Repo.aggregate(TurnImage, :count) == 1
  end

  test "a conflicting payload returns 409 without changing accepted work", c do
    first = request(c, %{"prompt" => "Review"}) |> json_response(200)

    assert request(c, %{"prompt" => "Different"}) |> json_response(409) ==
             %{"error" => "idempotency_conflict"}

    assert Repo.get!(Turn, first["turn_id"]).prompt == "Review"
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "retries report durable refusal without starting a new turn", c do
    first = request(c, %{"prompt" => "Review"}) |> json_response(200)
    {:ok, _} = PromptDelivery.refuse(c.user.id, c.conv.id, first["receipt_id"], "cancelled")
    retry = request(c, %{"prompt" => "Review"}) |> json_response(200)
    assert retry["receipt_id"] == first["receipt_id"]
    assert retry["status"] == "refused"
    assert retry["failure_reason"] == "cancelled"
    assert Repo.aggregate(Turn, :count) == 1
  end

  test "oversized keys are rejected rather than truncated", c do
    assert request(c, %{"prompt" => "Review"}, String.duplicate("x", 201))
           |> json_response(422) == %{"error" => "invalid_idempotency_key"}

    assert Repo.aggregate(Turn, :count) == 0
  end
end
