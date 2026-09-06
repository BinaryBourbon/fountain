defmodule Fountain.Conversations.LabelsTest do
  @moduledoc """
  Labels on a conversation (#1637): the rule, the merge, the filter.

  The doors are covered where they live — the API in
  `FountainWeb.ConversationLabelsTest`, the ACP extension in
  `Fountain.Conversations.ConversationServerACPTest` — so what is here is the
  behaviour every one of them inherits.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Labels

  describe "the limits" do
    test "a legal map passes" do
      assert :ok = Labels.check(%{"env" => "prod", "drift" => "true"})
      assert :ok = Labels.check(%{})
    end

    test "more than 32 entries names the key over the limit" do
      labels = for n <- 1..33, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      assert {:error, message} = Labels.check(labels)
      assert message =~ "at most 32 labels"
      assert message =~ ~s("033")
    end

    test "an over-long key names it, cut rather than echoed whole" do
      key = String.duplicate("k", 200)

      assert {:error, message} = Labels.check(%{key => "v"})
      assert message =~ "longer than 64 bytes"
      assert message =~ String.duplicate("k", 64) <> "..."
      refute message =~ String.duplicate("k", 65)
    end

    test "an over-long value names its key" do
      assert {:error, message} = Labels.check(%{"note" => String.duplicate("v", 257)})
      assert message =~ ~s("note")
      assert message =~ "longer than 256 bytes"
    end

    test "a non-string value names its key" do
      assert {:error, message} = Labels.check(%{"count" => 3})
      assert message =~ ~s("count")
      assert message =~ "string value"
    end

    test "an empty key is refused" do
      assert {:error, message} = Labels.check(%{"" => "v"})
      assert message =~ "must not be empty"
    end

    test "something that is not a map at all is refused" do
      assert {:error, _} = Labels.check(["env:prod"])
    end

    test "the boundary values are legal" do
      assert :ok =
               Labels.check(%{String.duplicate("k", 64) => String.duplicate("v", 256)})

      assert :ok = Labels.check(for(n <- 1..32, into: %{}, do: {"k#{n}", "v"}))
    end

    test "the same offending key is named on every run, whatever the map order" do
      labels = for n <- 1..40, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      assert {:error, first} = Labels.check(labels)
      assert {:error, second} = Labels.check(Map.new(Enum.shuffle(labels)))
      assert first == second
    end
  end

  describe "merge" do
    test "adds and overwrites, leaves the rest alone" do
      assert %{"a" => "2", "b" => "1"} = Labels.merge(%{"a" => "1", "b" => "1"}, %{"a" => "2"})
    end

    test "a null value removes the key" do
      assert %{"b" => "1"} = Labels.merge(%{"a" => "1", "b" => "1"}, %{"a" => nil})
    end

    test "removing a key that is not there is not an error" do
      assert %{"b" => "1"} = Labels.merge(%{"b" => "1"}, %{"a" => nil})
    end

    test "changed_keys reports written and removed, sorted" do
      current = %{"a" => "1", "b" => "1", "z" => "1"}
      incoming = %{"a" => "1", "b" => "2", "c" => "3", "z" => nil, "gone" => nil}

      # "a" is unchanged so it is not written; "gone" was never there, so
      # removing it removed nothing and the trail does not claim otherwise.
      assert {["b", "c"], ["z"]} = Labels.changed_keys(current, incoming)
    end
  end

  describe "the filter vocabulary" do
    test "splits on the first colon only" do
      assert {:ok, %{"path" => "a:b"}} = Labels.parse_filter(["path:a:b"])
    end

    test "combines repeated values" do
      assert {:ok, %{"env" => "prod", "drift" => "true"}} =
               Labels.parse_filter(["env:prod", "drift:true"])
    end

    test "an empty value is a legal filter" do
      assert {:ok, %{"env" => ""}} = Labels.parse_filter(["env:"])
    end

    test "a value with no colon is refused rather than guessed at" do
      assert {:error, :invalid_label_filter} = Labels.parse_filter(["prod"])
    end

    test "an empty key is refused" do
      assert {:error, :invalid_label_filter} = Labels.parse_filter([":prod"])
    end

    test "reads every repetition out of a raw query string" do
      assert ["env:prod", "drift:true"] =
               Labels.from_query_string("roots_only=true&label=env:prod&label=drift:true")
    end

    test "accepts the bracketed array form too" do
      assert ["env:prod"] = Labels.from_query_string("label%5B%5D=env%3Aprod")
    end
  end

  describe "on the row" do
    setup do
      user = insert_active_user()
      {:ok, user: user}
    end

    test "a conversation created with labels reads them back", %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      assert %{"env" => "prod"} = Conversations.get_conversation(conv.id, user.id).labels
    end

    test "a conversation created without labels has an empty map", %{user: user} do
      conv = insert_conversation(user_id: user.id)

      assert %{} == Conversations.get_conversation(conv.id, user.id).labels
    end

    test "the changeset refuses a write over the limits, naming the key", %{user: user} do
      conv = insert_conversation(user_id: user.id)

      assert {:error, changeset} =
               Conversations.merge_labels(conv, %{"note" => String.duplicate("v", 300)})

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ ~s("note")
    end

    test "the count ceiling counts the merged result, not the request", %{user: user} do
      thirty_two = for n <- 1..32, into: %{}, do: {"k#{n}", "v"}
      conv = insert_conversation(user_id: user.id, labels: thirty_two)

      assert {:error, changeset} = Conversations.merge_labels(conv, %{"one-too-many" => "v"})
      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ "at most 32 labels"
    end
  end

  describe "merge_labels/3" do
    setup do
      user = insert_active_user()
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})
      {:ok, user: user, conv: conv}
    end

    test "merges rather than replaces", %{conv: conv} do
      assert {:ok, updated} = Conversations.merge_labels(conv, %{"drift" => "true"})
      assert updated.labels == %{"env" => "staging", "drift" => "true"}
    end

    test "a null value removes one key", %{conv: conv} do
      assert {:ok, updated} = Conversations.merge_labels(conv, %{"env" => nil})
      assert updated.labels == %{}
    end

    test "records the keys that changed and never the values", %{user: user, conv: conv} do
      assert {:ok, _} = Conversations.merge_labels(conv, %{"drift" => "true", "env" => nil})

      assert [event] =
               user.id
               |> Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))

      assert event.metadata["keys"] == ["drift"]
      assert event.metadata["removed_keys"] == ["env"]
      assert event.metadata["label_count"] == 1
      refute event.metadata |> inspect() =~ "true"
    end

    test "a merge that changes nothing writes nothing and records nothing", %{
      user: user,
      conv: conv
    } do
      assert {:ok, same} = Conversations.merge_labels(conv, %{"env" => "staging"})
      assert same.updated_at == conv.updated_at

      assert [] =
               user.id
               |> Audit.list_recent_for_user(50)
               |> Enum.filter(&(&1.action == "conversation.labels_set"))
    end
  end

  describe "set_conversation_labels/4" do
    setup do
      user = insert_active_user()
      {key, _raw} = insert_sprite_api_key(user)

      mine =
        insert_conversation(user_id: user.id, callback_api_key_id: key.id, labels: %{"a" => "1"})

      theirs = insert_conversation(user_id: user.id)

      {:ok, user: user, key: key, mine: mine, theirs: theirs}
    end

    test "the owner's own key may label any of their conversations", %{
      user: user,
      theirs: theirs
    } do
      assert {:ok, updated} =
               Conversations.set_conversation_labels(theirs.id, user.id, %{"env" => "prod"})

      assert updated.labels == %{"env" => "prod"}
    end

    test "a sandbox token may label the conversation it was minted for", %{
      user: user,
      key: key,
      mine: mine
    } do
      assert {:ok, updated} =
               Conversations.set_conversation_labels(mine.id, user.id, %{"env" => "prod"},
                 sandbox_key_id: key.id,
                 actor: "sprite"
               )

      assert updated.labels == %{"a" => "1", "env" => "prod"}
    end

    test "a sandbox token may not label another conversation", %{
      user: user,
      key: key,
      theirs: theirs
    } do
      assert {:error, :sprite_may_not_label_another_conversation} =
               Conversations.set_conversation_labels(theirs.id, user.id, %{"env" => "prod"},
                 sandbox_key_id: key.id
               )

      assert Conversations.get_conversation(theirs.id, user.id).labels == %{}
    end

    test "another tenant's conversation reads as not found", %{user: user} do
      other = insert_conversation(user_id: insert_active_user().id)

      assert {:error, :not_found} =
               Conversations.set_conversation_labels(other.id, user.id, %{"env" => "prod"})
    end
  end

  describe "the list filter" do
    setup do
      user = insert_active_user()

      prod_drift =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "true"})

      prod_clean =
        insert_conversation(user_id: user.id, labels: %{"env" => "prod", "drift" => "false"})

      staging = insert_conversation(user_id: user.id, labels: %{"env" => "staging"})
      unlabelled = insert_conversation(user_id: user.id)

      {:ok,
       user: user,
       prod_drift: prod_drift,
       prod_clean: prod_clean,
       staging: staging,
       unlabelled: unlabelled}
    end

    defp ids(convs), do: convs |> Enum.map(& &1.id) |> MapSet.new()

    test "one pair keeps every conversation carrying it", context do
      found = Conversations.list_conversations(context.user.id, labels: %{"env" => "prod"})

      assert ids(found) == MapSet.new([context.prod_drift.id, context.prod_clean.id])
    end

    test "two pairs are combined with AND", context do
      found =
        Conversations.list_conversations(context.user.id,
          labels: %{"env" => "prod", "drift" => "true"}
        )

      assert ids(found) == MapSet.new([context.prod_drift.id])
    end

    test "a pair nothing carries matches nothing", context do
      assert [] = Conversations.list_conversations(context.user.id, labels: %{"env" => "qa"})
    end

    test "no filter leaves the list alone", context do
      assert MapSet.size(ids(Conversations.list_conversations(context.user.id))) == 4
      assert MapSet.size(ids(Conversations.list_conversations(context.user.id, labels: %{}))) == 4
    end

    test "the filter is tenant-scoped like every other", context do
      stranger = insert_active_user()
      insert_conversation(user_id: stranger.id, labels: %{"env" => "prod"})

      found = Conversations.list_conversations(context.user.id, labels: %{"env" => "prod"})
      assert ids(found) == MapSet.new([context.prod_drift.id, context.prod_clean.id])
    end

    test "combines with the other filters", context do
      agent = insert_agent(user_id: context.user.id)

      mine =
        insert_conversation(user_id: context.user.id, agent: agent, labels: %{"env" => "prod"})

      found =
        Conversations.list_conversations(context.user.id,
          agent_id: agent.id,
          labels: %{"env" => "prod"}
        )

      assert ids(found) == MapSet.new([mine.id])
    end
  end
end
