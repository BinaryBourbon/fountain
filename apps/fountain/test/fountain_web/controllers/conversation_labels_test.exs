defmodule FountainWeb.ConversationLabelsTest do
  @moduledoc """
  Labels over the wire (#1637): create, read back, the repeatable AND filter,
  the merge route and who is allowed to call it.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "POST /api/conversations with labels" do
    test "creates with them and returns them", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      Mimic.stub(Fountain.Conversations, :start_or_resume_conversation, fn attrs, _opts ->
        conv = insert_conversation(user_id: user.id, agent: agent, labels: attrs["labels"])
        {:ok, Conversations.get_conversation_with_activity(conv.id, user.id), :created}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "labels" => %{"env" => "prod", "drift" => "true"}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["labels"] == %{"env" => "prod", "drift" => "true"}
    end

    test "a conversation with no labels serves an empty object, never null", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      assert %{"data" => %{"labels" => %{}}} = json_response(conn, 200)
    end
  end

  describe "GET /api/conversations?label=" do
    setup %{user: user} do
      prod_drift =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "true"})

      prod_clean = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})
      staging = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})

      {:ok, prod_drift: prod_drift, prod_clean: prod_clean, staging: staging}
    end

    defp listed(conn),
      do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["id"])

    test "one pair keeps the conversations carrying it", context do
      ids =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?label=env:prod")
        |> listed()

      assert Enum.sort(ids) == Enum.sort([context.prod_drift.id, context.prod_clean.id])
    end

    test "a repeated label is combined with AND", context do
      ids =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?label=env:prod&label=drift:true")
        |> listed()

      assert ids == [context.prod_drift.id]
    end

    test "combines with the other filters", context do
      ids =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?status=pending&label=env:staging")
        |> listed()

      assert ids == [context.staging.id]
    end

    test "a value splits on its first colon only", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id, labels: %{"path" => "apps/fountain:lib"})

      ids =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations?label=path:apps/fountain:lib")
        |> listed()

      assert ids == [conv.id]
    end

    test "a value with no colon is a 400 rather than a silent match-all", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> get("/api/conversations?label=prod")

      assert %{"error" => "invalid_label_filter"} = json_response(conn, 400)
    end
  end

  describe "PATCH /api/conversations/:id/labels" do
    setup %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})
      {:ok, conv: conv}
    end

    test "merges into what is already there", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{context.conv.id}/labels", %{
          "labels" => %{"drift" => "true"}
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["labels"] == %{"env" => "staging", "drift" => "true"}
    end

    test "a null value removes one key", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{context.conv.id}/labels", %{
          "labels" => %{"env" => nil, "run" => "17"}
        })

      assert %{"data" => %{"labels" => %{"run" => "17"}}} = json_response(conn, 200)
    end

    test "another tenant's conversation is a 404", context do
      other = insert_conversation(user_id: insert_active_user().id)

      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{other.id}/labels", %{"labels" => %{"env" => "prod"}})

      assert json_response(conn, 404)
    end

    test "a body without a labels object is a 422", context do
      conn =
        context.conn
        |> authed_with_key(context.raw_key)
        |> patch_json("/api/conversations/#{context.conv.id}/labels", %{"labels" => "env=prod"})

      assert %{"error" => _} = json_response(conn, 422)
    end
  end

  describe "the limits over the wire" do
    setup %{user: user} do
      {:ok, conv: insert_conversation(user_id: user.id)}
    end

    defp label_error(context, labels) do
      context.conn
      |> authed_with_key(context.raw_key)
      |> patch_json("/api/conversations/#{context.conv.id}/labels", %{"labels" => labels})
      |> json_response(422)
      |> get_in(["errors", "labels"])
      |> List.first()
    end

    test "too many entries names the key over the limit", context do
      labels = for n <- 1..33, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      message = label_error(context, labels)
      assert message =~ "at most 32 labels"
      assert message =~ ~s("033")
    end

    test "an over-long key names it", context do
      message = label_error(context, %{String.duplicate("k", 65) => "v"})

      assert message =~ "longer than 64 bytes"
      assert message =~ String.duplicate("k", 64)
    end

    test "an over-long value names its key", context do
      message = label_error(context, %{"note" => String.duplicate("v", 257)})

      assert message =~ ~s("note")
      assert message =~ "longer than 256 bytes"
    end
  end

  describe "a sandbox callback token" do
    setup %{user: user} do
      {key, raw} = insert_sprite_api_key(user)
      mine = insert_conversation(user_id: user.id, callback_api_key_id: key.id)
      theirs = insert_conversation(user_id: user.id)

      {:ok, sprite_key: raw, mine: mine, theirs: theirs}
    end

    test "labels the conversation it was minted for", context do
      conn =
        context.conn
        |> authed_with_key(context.sprite_key)
        |> patch_json("/api/conversations/#{context.mine.id}/labels", %{
          "labels" => %{"drift" => "true"}
        })

      assert %{"data" => %{"labels" => %{"drift" => "true"}}} = json_response(conn, 200)
    end

    test "is refused on another conversation of the same account", context do
      conn =
        context.conn
        |> authed_with_key(context.sprite_key)
        |> patch_json("/api/conversations/#{context.theirs.id}/labels", %{
          "labels" => %{"drift" => "true"}
        })

      assert %{"error" => "sprite_may_not_label_another_conversation"} = json_response(conn, 403)
      assert Conversations._unsafe_get_conversation!(context.theirs.id).labels == %{}
    end

    test "records the write as the sprite, with keys and no values", context do
      context.conn
      |> authed_with_key(context.sprite_key)
      |> patch_json("/api/conversations/#{context.mine.id}/labels", %{
        "labels" => %{"drift" => "true"}
      })

      assert [event] =
               context.user.id
               |> Fountain.Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))

      assert event.actor == "sprite"
      assert event.metadata["keys"] == ["drift"]
      refute inspect(event.metadata) =~ "true"
    end
  end
end
