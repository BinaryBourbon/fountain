defmodule FountainWeb.SchemasTest do
  @moduledoc """
  The published OpenAPI spec against what the code actually does.

  #197 removed the unreachable `completed` status from the Conversation
  schema, but the OpenAPI enum kept advertising it — so generated clients
  handled a status the server cannot emit, and `source` /
  `parent_conversation_id` were emitted but undocumented. These pin the
  spec to the schema and the JSON view so the next drift fails a test
  instead of an integration.
  """

  use ExUnit.Case, async: true

  alias Fountain.Conversations.Conversation

  defp conversation_schema, do: FountainWeb.Schemas.Conversation.schema()

  test "the status enum matches the statuses the server can emit" do
    assert conversation_schema().properties.status.enum == Conversation.statuses()
  end

  test "every field ConversationJSON emits is documented" do
    emitted =
      %Conversation{id: Ecto.UUID.generate()}
      |> FountainWeb.ConversationJSON.data()
      |> Map.keys()
      |> MapSet.new()

    documented = conversation_schema().properties |> Map.keys() |> MapSet.new()

    missing = MapSet.difference(emitted, documented)
    assert MapSet.size(missing) == 0, "emitted but undocumented: #{inspect(MapSet.to_list(missing))}"
  end

  # #571 brought the API-key views into the spec. Same drift guard: the
  # listing must never grow a field the schema does not mention, because the
  # one field that must never appear there is the key itself.
  describe "API key views (issue #571)" do
    defp api_key, do: %Fountain.Accounts.ApiKey{id: Ecto.UUID.generate(), key_prefix: "ftn_abc"}

    test "every field the key listing emits is documented" do
      [emitted] = FountainWeb.ApiKeyJSON.index(%{keys: [api_key()]}).data

      documented =
        FountainWeb.Schemas.ApiKey.schema().properties |> Map.keys() |> MapSet.new()

      missing = MapSet.difference(emitted |> Map.keys() |> MapSet.new(), documented)
      assert MapSet.size(missing) == 0, "emitted but undocumented: #{inspect(MapSet.to_list(missing))}"
    end

    test "the listing schema has no field that could carry key material" do
      documented = FountainWeb.Schemas.ApiKey.schema().properties |> Map.keys()
      refute :key in documented
      refute :key_hash in documented
    end

    test "every field the creation response emits is documented" do
      emitted = FountainWeb.ApiKeyJSON.created(%{key: api_key(), raw_key: "ftn_abc_secret"})

      documented =
        FountainWeb.Schemas.ApiKeyCreatedResponse.schema().properties |> Map.keys() |> MapSet.new()

      missing = MapSet.difference(emitted |> Map.keys() |> MapSet.new(), documented)
      assert MapSet.size(missing) == 0, "emitted but undocumented: #{inspect(MapSet.to_list(missing))}"
    end
  end
end
