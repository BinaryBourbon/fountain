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

  test "an acp row parses through ACP.Blocks" do
    ev = %{
      kind: "output",
      stream: "acp",
      data:
        acp(%{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => "hi"}
        })
    }

    assert [%{kind: :text, body: "hi"}] = Blocks.for_event(ev)
  end

  test "non-ACP streams do not produce blocks" do
    legacy =
      Jason.encode!(%{
        "type" => "assistant",
        "message" => %{"content" => [%{"type" => "text", "text" => "old style"}]}
      })

    for stream <- ["stdout", "stderr", nil], data <- [legacy, "diagnostic output", text("ACP")] do
      assert [] = Blocks.for_event(%{kind: "output", stream: stream, data: data})
    end
  end

  test "assistant text includes only ACP output text, joined and trimmed" do
    events = [
      %{
        kind: "output",
        stream: "stdout",
        data:
          Jason.encode!(%{
            "type" => "assistant",
            "message" => %{"content" => [%{"type" => "text", "text" => "old output"}]}
          })
      },
      %{kind: "output", stream: "acp", data: text("  hello") <> "\n" <> text(" world  ")},
      %{kind: "output", stream: "stderr", data: text("diagnostic")},
      %{kind: "stage", stream: "acp", data: text("stage")},
      %{
        kind: "output",
        stream: "acp",
        data:
          acp(%{
            "sessionUpdate" => "agent_thought_chunk",
            "content" => %{"type" => "text", "text" => "thinking"}
          })
      },
      %{kind: "output", stream: "acp", data: nil}
    ]

    assert Blocks.assistant_text(events) == "hello world"
    assert Blocks.assistant_text([hd(events)]) == ""
    assert Blocks.assistant_text([]) == ""
  end

  defp text(body) do
    acp(%{
      "sessionUpdate" => "agent_message_chunk",
      "content" => %{"type" => "text", "text" => body}
    })
  end

  test "no data, no blocks" do
    assert [] = Blocks.for_event(%{kind: "stage", stream: nil, data: nil})
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

    for b <- Blocks.for_event(ev) do
      assert Atom.to_string(b.kind) in Blocks.kinds()
    end
  end
end
