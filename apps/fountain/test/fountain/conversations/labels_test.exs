defmodule Fountain.Conversations.LabelsTest do
  @moduledoc """
  Labels on a conversation (#1637): the rule.

  What is here is the behaviour every writer inherits, because
  `Fountain.Conversations.Conversation.changeset/2` is the only thing that
  puts the column on a row.
  """

  use Fountain.DataCase, async: true

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

    # Postgres refuses a NUL inside a jsonb string, so an unchecked one is a
    # raised Postgrex.Error rather than a refusal — a 500 on the HTTP doors
    # and a dead ConversationServer on the ACP one.
    test "a NUL byte in a value names its key" do
      assert {:error, message} = Labels.check(%{"note" => "a\u0000b"})
      assert message =~ ~s("note")
      assert message =~ "NUL byte"
    end

    test "a NUL byte in a key is refused" do
      assert {:error, message} = Labels.check(%{"a\u0000b" => "v"})
      assert message =~ "NUL byte"
    end

    test "the boundary values are legal" do
      assert :ok =
               Labels.check(%{String.duplicate("k", 64) => String.duplicate("v", 256)})

      assert :ok = Labels.check(for(n <- 1..32, into: %{}, do: {"k#{n}", "v"}))
    end

    test "an over-long key is cut to a whole codepoint, so the message stays encodable" do
      # Cutting at 64 *bytes* lands mid-character here: "é" is two bytes, so
      # byte 64 is the tail of one. A message sliced there is not valid UTF-8
      # and Jason.encode! would raise on it instead of rendering the 422.
      key = String.duplicate("é", 40)

      assert {:error, message} = Labels.check(%{key => "v"})
      assert String.valid?(message)
      assert {:ok, _} = Jason.encode(%{errors: %{labels: [message]}})
    end

    test "the same offending key is named on every run, whatever the map order" do
      labels = for n <- 1..40, into: %{}, do: {String.pad_leading("#{n}", 3, "0"), "x"}

      assert {:error, first} = Labels.check(labels)
      assert {:error, second} = Labels.check(Map.new(Enum.shuffle(labels)))
      assert first == second
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

    # The wiring, not the rule: `Conversation.changeset/2` is what every
    # writer of the column goes through, so `check/1` running from there is
    # what makes the limits inescapable rather than advisory.
    test "the changeset refuses a write over the limits, naming the key", %{user: user} do
      conv = insert_conversation(user_id: user.id)
      long = String.duplicate("v", Labels.max_value_bytes() + 1)

      assert {:error, changeset} =
               Conversations.update_conversation(conv, %{labels: %{"note" => long}})

      assert %{labels: [message]} = errors_on(changeset)
      assert message =~ ~s("note")
    end

    test "an unrelated update leaves the labels alone", %{user: user} do
      conv = insert_conversation(user_id: user.id, labels: %{"env" => "prod"})

      assert {:ok, updated} = Conversations.update_conversation(conv, %{title: "renamed"})
      assert updated.labels == %{"env" => "prod"}
    end
  end
end
