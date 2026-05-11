defmodule FountainWeb.ConversationControllerTest do
  use FountainWeb.ConnCase, async: true

  alias FountainWeb.ConversationController

  setup do
    user = insert_verified_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/conversations" do
    test "returns 200 and lists user's conversations", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert conv.id in ids
    end

    test "does not include conversations belonging to other users", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_conv.id in ids
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/conversations")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:id" do
    test "returns 200 with the conversation for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == conv.id
    end

    test "returns 404 when the conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      conn = get(conn, "/api/conversations/#{conv.id}")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:conversation_id/turns" do
    test "returns 200 with turns list for the authenticated user", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, [])

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert turn.id in ids
    end

    test "returns 200 with an empty list when there are no turns", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns 404 when the conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}/turns")

      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/conversations/:id" do
    test "deletes the conversation and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{conv.id}")

      assert conn.status == 204
    end

    test "returns 404 when the conversation belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_verified_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{other_conv.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      conn = delete(conn, "/api/conversations/#{conv.id}")
      assert json_response(conn, 401)
    end
  end

  describe "infer_provenance/1" do
    test "returns {\"api\", nil} when header is nil" do
      assert ConversationController.infer_provenance(nil) == {"api", nil}
    end

    test "returns {\"api\", nil} when header is an empty string" do
      assert ConversationController.infer_provenance("") == {"api", nil}
    end

    test "returns {\"agent\", id} when header contains a conversation id" do
      assert ConversationController.infer_provenance("some-conv-uuid") == {"agent", "some-conv-uuid"}
    end
  end
end
