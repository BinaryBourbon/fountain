defmodule Fountain.Conversations.BlocksTest do
  use ExUnit.Case, async: true

  alias Fountain.Conversations.Blocks

  defp acp(update) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{"sessionId" => "s", "update" => update}
    })
  end

  test "an acp row parses through ACP.Blocks whatever the runtime" do
    ev = %{
      kind: "output",
      stream: "acp",
      data:
        acp(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hi"}
        })
    }

    assert [%{kind: :text, body: "hi"}] = Blocks.for_event(ev, "gemini")
  end

  test "a stdout row parses through the runtime's legacy dialect" do
    ev = %{
      kind: "output",
      stream: "stdout",
      data:
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "old style"}]}
        })
    }

    assert [%{kind: :text, body: "old style"}] = Blocks.for_event(ev, "claude")
    assert [%{kind: :raw}] = Blocks.for_event(ev, "unknown-runtime")
  end

  test "no data, no blocks" do
    assert [] = Blocks.for_event(%{kind: "stage", stream: nil, data: nil}, "claude")
  end

  test "to_json stringifies the kind and renames error?" do
    assert %{"kind" => "tool_result", "tool_id" => "t1", "body" => "x", "error" => true} =
             Blocks.to_json(%{kind: :tool_result, tool_id: "t1", body: "x", error?: true})

    assert %{"kind" => "text", "body" => "b"} = Blocks.to_json(%{kind: :text, body: "b"})
  end

  test "every kind the parsers emit is in kinds/0" do
    ev = %{
      kind: "output",
      stream: "acp",
      data:
        acp(%{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "c",
          "title" => "Read"
        })
    }

    for b <- Blocks.for_event(ev, "claude") do
      assert Atom.to_string(b.kind) in Blocks.kinds()
    end
  end
end
