defmodule FountainBuzz.McpTest do
  use ExUnit.Case, async: true

  alias FountainBuzz.Mcp

  # A ctx whose exec records the call and returns a canned result, so the tool
  # logic is tested without a real `buzz` binary or key.
  defp ctx(result \\ {~s({"accepted":true,"event_id":"abc"}), 0}) do
    test = self()

    %{
      buzz_bin: "/fake/buzz",
      env: [{"BUZZ_PRIVATE_KEY", "nsec1secret"}, {"BUZZ_RELAY_URL", "https://relay"}],
      exec: fn bin, argv, env ->
        send(test, {:exec, bin, argv, env})
        result
      end,
      audit: fn tool, args -> send(test, {:audit, tool, args}) end
    }
  end

  describe "protocol" do
    test "initialize advertises tools capability and protocol version" do
      resp = Mcp.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}, ctx())
      assert resp["id"] == 1
      assert resp["result"].capabilities.tools == %{}
      assert is_binary(resp["result"].protocolVersion)
      assert resp["result"].serverInfo.name == "fountain-buzz"
    end

    test "tools/list returns send_message and react" do
      resp = Mcp.handle(%{"id" => 2, "method" => "tools/list"}, ctx())
      names = Enum.map(resp["result"].tools, & &1.name)
      assert "buzz_send_message" in names
      assert "buzz_react" in names
    end

    test "a notification gets no reply" do
      assert Mcp.handle(%{"method" => "notifications/initialized"}, ctx()) == :noreply
    end

    test "an unknown method is a JSON-RPC method-not-found error" do
      resp = Mcp.handle(%{"id" => 9, "method" => "does/not/exist"}, ctx())
      assert resp["error"]["code"] == -32_601
    end
  end

  describe "buzz_send_message" do
    test "shells out with channel + content, credentials in env not argv" do
      req = %{
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "buzz_send_message",
          "arguments" => %{"channel" => "chan-1", "content" => "hello there"}
        }
      }

      resp = Mcp.handle(req, ctx())

      assert_received {:exec, "/fake/buzz", argv, env}
      assert argv == ["messages", "send", "--channel", "chan-1", "--content", "hello there"]
      # The nsec travels in the environment, never in the argv the process list shows.
      assert {"BUZZ_PRIVATE_KEY", "nsec1secret"} in env
      refute Enum.any?(argv, &String.contains?(&1, "nsec1"))

      assert resp["result"].isError == false
      assert [%{type: "text", text: out}] = resp["result"].content
      assert out =~ "accepted"
      assert_received {:audit, "buzz_send_message", _}
    end

    test "threads a reply when reply_to is given" do
      req = %{
        "id" => 4,
        "method" => "tools/call",
        "params" => %{
          "name" => "buzz_send_message",
          "arguments" => %{"channel" => "c", "content" => "re", "reply_to" => "evt-1"}
        }
      }

      Mcp.handle(req, ctx())
      assert_received {:exec, _, argv, _}
      assert Enum.chunk_every(argv, 1) |> List.flatten() |> Enum.member?("--reply-to")
      assert "evt-1" in argv
    end

    test "missing content is a tool error, not a crash, and does not shell out" do
      req = %{
        "id" => 5,
        "method" => "tools/call",
        "params" => %{"name" => "buzz_send_message", "arguments" => %{"channel" => "c"}}
      }

      resp = Mcp.handle(req, ctx())
      assert resp["result"].isError == true
      refute_received {:exec, _, _, _}
    end

    test "a nonzero buzz exit surfaces as a tool error carrying the output" do
      req = %{
        "id" => 6,
        "method" => "tools/call",
        "params" => %{
          "name" => "buzz_send_message",
          "arguments" => %{"channel" => "c", "content" => "x"}
        }
      }

      resp = Mcp.handle(req, ctx({"relay error 403", 3}))
      assert resp["result"].isError == true
      assert [%{text: out}] = resp["result"].content
      assert out =~ "403"
      # A failed publish must not audit.
      refute_received {:audit, _, _}
    end
  end

  describe "buzz_react" do
    test "shells out with event + emoji" do
      req = %{
        "id" => 7,
        "method" => "tools/call",
        "params" => %{
          "name" => "buzz_react",
          "arguments" => %{"event" => "evt-9", "emoji" => "👍"}
        }
      }

      resp = Mcp.handle(req, ctx())
      assert_received {:exec, _, ["reactions", "add", "--event", "evt-9", "--emoji", "👍"], _}
      assert resp["result"].isError == false
    end
  end
end
