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
end
