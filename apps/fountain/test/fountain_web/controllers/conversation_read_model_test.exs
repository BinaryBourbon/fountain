defmodule FountainWeb.ConversationReadModelTest do
  @moduledoc """
  The conversation read-model pieces that existed only in the LiveView layer
  (#520): title, read state, turn counts, the roots_only filter, and the spawn
  tree an agent needs to enumerate what it fanned out.
  """

  use FountainWeb.ConnCase, async: true

  alias Fountain.Conversations

  setup do
    user = insert_verified_user()
    {_rec, key} = insert_api_key(user)
    {:ok, user: user, key: key}
  end

  describe "conversation JSON" do
    test "index carries title, turn_count, read state and unread", %{
      conn: conn,
      user: user,
      key: key
    } do
      conv = insert_conversation(user_id: user.id, title: "Ship the thing")
      insert_turn(conv)
      insert_turn(conv, turn_number: 2)

      [json] =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations")
        |> json_response(200)
        |> Map.fetch!("data")

      assert json["title"] == "Ship the thing"
      assert json["turn_count"] == 2
      assert json["last_read_at"] == nil
      assert json["last_active_at"]
      assert json["unread"] == true
    end

    test "show reports the same numbers as index, not zeroes", %{
      conn: conn,
      user: user,
      key: key
    } do
      # get_conversation/2 leaves turn_count at its default; serving that from
      # show would report 0 turns for a conversation with turns.
      conv = insert_conversation(user_id: user.id)
      insert_turn(conv)

      json =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert json["turn_count"] == 1
      assert json["last_active_at"]
    end

    test "a read conversation reports unread false", %{conn: conn, user: user, key: key} do
      conv = insert_conversation(user_id: user.id)
      :ok = Conversations.mark_read(conv.id, user.id)

      json =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert json["last_read_at"]
      assert json["unread"] == false
    end
  end

  describe "GET /api/conversations?roots_only" do
    setup %{user: user} do
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      {:ok, root: root, child: child}
    end

    test "defaults to including sub-conversations", %{
      conn: conn,
      key: key,
      root: root,
      child: child
    } do
      ids =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      assert root.id in ids
      assert child.id in ids
    end

    test "roots_only=true excludes them", %{conn: conn, key: key, root: root, child: child} do
      ids =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations?roots_only=true")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      assert root.id in ids
      refute child.id in ids
    end

    test "roots_only=false is the default behaviour, not an error", %{
      conn: conn,
      key: key,
      child: child
    } do
      ids =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations?roots_only=false")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])

      assert child.id in ids
    end
  end

  describe "POST /api/conversations/:id/read" do
    test "marks the conversation read", %{conn: conn, user: user, key: key} do
      conv = insert_conversation(user_id: user.id)

      conn
      |> authed_with_key(key)
      |> post("/api/conversations/#{conv.id}/read")
      |> response(204)

      assert Conversations.get_conversation(conv.id, user.id).last_read_at
    end

    test "is idempotent", %{conn: conn, user: user, key: key} do
      conv = insert_conversation(user_id: user.id)

      for _ <- 1..2 do
        build_conn()
        |> authed_with_key(key)
        |> post("/api/conversations/#{conv.id}/read")
        |> response(204)
      end

      assert Conversations.get_conversation(conv.id, user.id).last_read_at
    end

    test "another tenant's conversation is 404 and stays unread", %{conn: conn, key: key} do
      other = insert_verified_user()
      other_conv = insert_conversation(user_id: other.id)

      conn
      |> authed_with_key(key)
      |> post("/api/conversations/#{other_conv.id}/read")
      |> json_response(404)

      refute Conversations.get_conversation(other_conv.id, other.id).last_read_at
    end
  end

  describe "GET /api/conversations/:id/tree" do
    test "returns ancestors and descendants, flat, with parent pointers", %{
      conn: conn,
      user: user,
      key: key
    } do
      root = insert_conversation(user_id: user.id)
      child = insert_conversation(user_id: user.id, parent_conversation_id: root.id)
      grandchild = insert_conversation(user_id: user.id, parent_conversation_id: child.id)

      # Asked from the middle: the tree is the whole family, not the subtree.
      nodes =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{child.id}/tree")
        |> json_response(200)
        |> Map.fetch!("data")

      by_id = Map.new(nodes, &{&1["id"], &1})

      assert Map.keys(by_id) |> Enum.sort() == Enum.sort([root.id, child.id, grandchild.id])
      assert by_id[root.id]["parent_id"] == nil
      assert by_id[child.id]["parent_id"] == root.id
      assert by_id[grandchild.id]["parent_id"] == child.id
      assert by_id[grandchild.id]["status"]
      assert by_id[grandchild.id]["source"]
    end

    test "a conversation with no relatives is a tree of one", %{conn: conn, user: user, key: key} do
      conv = insert_conversation(user_id: user.id)

      nodes =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}/tree")
        |> json_response(200)
        |> Map.fetch!("data")

      assert Enum.map(nodes, & &1["id"]) == [conv.id]
    end

    test "another tenant's conversation is 404, and no ids leak", %{conn: conn, key: key} do
      other = insert_verified_user()
      other_root = insert_conversation(user_id: other.id)
      other_child = insert_conversation(user_id: other.id, parent_conversation_id: other_root.id)

      conn =
        conn
        |> authed_with_key(key)
        |> get("/api/conversations/#{other_root.id}/tree")

      assert json_response(conn, 404)
      refute conn.resp_body =~ other_child.id
    end

    test "requires authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)

      conn
      |> put_req_header("accept", "application/json")
      |> get("/api/conversations/#{conv.id}/tree")
      |> json_response(401)
    end
  end
end
