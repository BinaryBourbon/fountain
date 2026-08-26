defmodule Fountain.CallerToolsTest do
  use ExUnit.Case, async: true

  alias Fountain.CallerTools

  @tool %{
    "type" => "function",
    "function" => %{
      "name" => "lookup_order",
      "description" => "Find an order",
      "parameters" => %{"type" => "object", "properties" => %{"id" => %{"type" => "string"}}}
    }
  }

  describe "from_openai/2" do
    test "normalises function tools and fills the blanks" do
      assert {:ok, [tool]} = CallerTools.from_openai([@tool], nil)
      assert tool["name"] == "lookup_order"
      assert tool["description"] == "Find an order"
      assert tool["parameters"]["type"] == "object"

      assert {:ok, [bare]} =
               CallerTools.from_openai(
                 [%{"type" => "function", "function" => %{"name" => "x"}}],
                 "auto"
               )

      assert bare["description"] == ""
      assert bare["parameters"] == %{"type" => "object", "properties" => %{}}
    end

    test "no tools is an empty list, and tool_choice none unregisters" do
      assert {:ok, []} = CallerTools.from_openai(nil, nil)
      assert {:ok, []} = CallerTools.from_openai([], nil)
      assert {:ok, []} = CallerTools.from_openai([@tool], "none")
    end

    test "required and a named tool are refused: Fountain cannot force an agent" do
      assert {:error, msg} = CallerTools.from_openai([@tool], "required")
      assert msg =~ "cannot force"

      assert {:error, _} =
               CallerTools.from_openai([@tool], %{
                 "type" => "function",
                 "function" => %{"name" => "x"}
               })
    end

    test "rejects bad names, the reserved wait tool, duplicates and non-objects" do
      bad = fn name -> [%{"type" => "function", "function" => %{"name" => name}}] end
      assert {:error, msg} = CallerTools.from_openai(bad.("has space"), nil)
      assert msg =~ "must match"
      assert {:error, msg} = CallerTools.from_openai(bad.(CallerTools.wait_tool()), nil)
      assert msg =~ "reserved"
      assert {:error, msg} = CallerTools.from_openai(bad.("a") ++ bad.("a"), nil)
      assert msg =~ "unique"
      assert {:error, _} = CallerTools.from_openai("nope", nil)
      assert {:error, _} = CallerTools.from_openai([%{"type" => "retrieval"}], nil)
    end
  end

  describe "from_agui/1" do
    test "reads the flat AG-UI shape" do
      assert {:ok, [%{"name" => "confirm", "parameters" => %{"type" => "object"}}]} =
               CallerTools.from_agui([
                 %{"name" => "confirm", "parameters" => %{"type" => "object"}}
               ])

      assert {:error, _} = CallerTools.from_agui([%{"description" => "no name"}])
    end
  end

  describe "tool_answers/1" do
    test "reads the trailing tool messages, either id spelling, either content shape" do
      messages = [
        %{"role" => "user", "content" => "go"},
        %{"role" => "assistant", "tool_calls" => []},
        %{"role" => "tool", "tool_call_id" => "call_1", "content" => "one"},
        %{
          "role" => "tool",
          "toolCallId" => "call_2",
          "content" => [%{"type" => "text", "text" => "two"}]
        },
        %{"role" => "tool", "tool_call_id" => "call_3", "content" => %{"n" => 3}}
      ]

      assert CallerTools.tool_answers(messages) == %{
               "call_1" => "one",
               "call_2" => "two",
               "call_3" => ~s({"n":3})
             }
    end

    test "is empty when the newest message is not a tool answer" do
      assert CallerTools.tool_answers([
               %{"role" => "tool", "tool_call_id" => "old", "content" => "x"},
               %{"role" => "user", "content" => "new prompt"}
             ]) == %{}

      assert CallerTools.tool_answers([]) == %{}
      assert CallerTools.tool_answers(nil) == %{}
    end
  end

  test "to_openai_call/1 encodes the arguments as a JSON string" do
    assert %{id: "call_1", type: "function", function: %{name: "f", arguments: ~s({"a":1})}} =
             CallerTools.to_openai_call(%{id: "call_1", name: "f", arguments: %{"a" => 1}})

    assert %{function: %{arguments: "{}"}} =
             CallerTools.to_openai_call(%{id: "call_1", name: "f", arguments: nil})
  end

  test "conversation_mcp_servers/2 serves one http entry only when tools are registered" do
    conv = %{id: "c1", caller_tools: [%{"name" => "x"}]}

    assert [%{name: "fountain-caller", type: "http", url: url, headers: [h]}] =
             CallerTools.conversation_mcp_servers(conv, "tok")

    assert String.ends_with?(url, "/api/mcp/caller/c1")
    assert h == %{name: "Authorization", value: "Bearer tok"}

    assert [] = CallerTools.conversation_mcp_servers(%{id: "c1", caller_tools: []}, "tok")
    assert [] = CallerTools.conversation_mcp_servers(conv, nil)
  end

  describe "Mcp" do
    alias Fountain.CallerTools.Mcp

    test "tools/list is the registered tools plus the wait tool" do
      conv = %{
        id: "c1",
        caller_tools: [%{"name" => "x", "description" => "d", "parameters" => %{}}]
      }

      assert %{
               result: %{
                 tools: [%{name: "x", description: "d"}, %{name: "wait_for_caller_result"}]
               }
             } =
               Mcp.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, %{
                 conversation: conv
               })
    end

    test "initialize, ping, notifications and unknown methods" do
      ctx = %{conversation: %{id: "c1", caller_tools: []}}

      assert %{result: %{serverInfo: %{name: "fountain-caller"}}} =
               Mcp.handle(%{"method" => "initialize", "id" => 1}, ctx)

      assert %{result: %{}} = Mcp.handle(%{"method" => "ping", "id" => 2}, ctx)
      assert :noreply = Mcp.handle(%{"method" => "notifications/initialized"}, ctx)
      assert %{error: %{code: -32_601}} = Mcp.handle(%{"method" => "nope", "id" => 3}, ctx)
      assert %{error: %{code: -32_600}} = Mcp.handle(%{}, ctx)
    end

    test "tools/call of an unregistered tool is a tool error, not a park" do
      ctx = %{conversation: %{id: "c1", caller_tools: [%{"name" => "x"}]}}

      assert %{result: %{isError: true, content: [%{text: "unknown tool: y"}]}} =
               Mcp.handle(
                 %{
                   "method" => "tools/call",
                   "id" => 1,
                   "params" => %{"name" => "y", "arguments" => %{}}
                 },
                 ctx
               )
    end
  end
end
