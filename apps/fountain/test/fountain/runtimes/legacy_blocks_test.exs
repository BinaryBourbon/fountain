defmodule Fountain.Runtimes.LegacyBlocksTest do
  use ExUnit.Case, async: true

  alias Fountain.Runtimes.LegacyBlocks

  # First tests these parsers have ever had: they spent their whole life as
  # private clauses of a LiveView (#642). Gemini's dialect is live; the other
  # three are frozen and render pre-ACP history only — these tests pin the
  # frozen behavior so a refactor can't silently change how old transcripts
  # render.

  defp line(map), do: Jason.encode!(map)

  describe "claude (frozen)" do
    test "init, text, thinking, tool_use, tool_result, result" do
      assert [%{kind: :init, summary: summary}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "system",
                   "subtype" => "init",
                   "model" => "claude-sonnet-4-6",
                   "tools" => ["a", "b"]
                 }),
                 "claude"
               )

      assert summary =~ "claude-sonnet-4-6"
      assert summary =~ "2 tools"

      assert [%{kind: :text, body: "hi"}, %{kind: :thinking, body: "hmm"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "assistant",
                   "message" => %{
                     "content" => [
                       %{"type" => "text", "text" => "hi"},
                       %{"type" => "thinking", "thinking" => "hmm"}
                     ]
                   }
                 }),
                 "claude"
               )

      assert [%{kind: :tool_use, id: "t1", name: "Bash", summary: "ls"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "assistant",
                   "message" => %{
                     "content" => [
                       %{
                         "type" => "tool_use",
                         "id" => "t1",
                         "name" => "Bash",
                         "input" => %{"command" => "ls"}
                       }
                     ]
                   }
                 }),
                 "claude"
               )

      assert [%{kind: :tool_result, tool_id: "t1", body: "ok", error?: false}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "user",
                   "message" => %{
                     "content" => [%{"tool_use_id" => "t1", "content" => "ok"}]
                   }
                 }),
                 "claude"
               )

      assert [%{kind: :result, body: body}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "result",
                   "subtype" => "success",
                   "duration_ms" => 1500,
                   "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
                 }),
                 "claude"
               )

      assert body == "success · 1.5s · in:10 out:5"
    end

    test "rate_limit_event renders nothing" do
      assert [] = LegacyBlocks.from_line(line(%{"type" => "rate_limit_event"}), "claude")
    end
  end

  describe "codex (frozen)" do
    test "thread, message, tool item, usage, errors" do
      assert [%{kind: :init, summary: "thread: th_1"}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "thread.started", "thread_id" => "th_1"}),
                 "codex"
               )

      assert [%{kind: :text, body: "hello"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "item.completed",
                   "item" => %{"type" => "agent_message", "text" => "hello"}
                 }),
                 "codex"
               )

      assert [%{kind: :tool_use, name: "command_execution"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "item.completed",
                   "item" => %{"type" => "command_execution", "command" => "ls"}
                 }),
                 "codex"
               )

      assert [%{kind: :result, body: "in:7 out:3"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "turn.completed",
                   "usage" => %{"input_tokens" => 7, "output_tokens" => 3}
                 }),
                 "codex"
               )

      assert [%{kind: :error, body: "boom"}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "turn.failed", "error" => %{"message" => "boom"}}),
                 "codex"
               )
    end
  end

  describe "gemini (live, #659)" do
    test "init, assistant text, tool pair, result" do
      assert [%{kind: :init, summary: summary}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "init", "model" => "gemini-2.5-pro"}),
                 "gemini"
               )

      assert summary =~ "gemini-2.5-pro"

      assert [] =
               LegacyBlocks.from_line(
                 line(%{"type" => "message", "role" => "user", "content" => "prompt"}),
                 "gemini"
               )

      assert [%{kind: :text, body: "answer"}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "message", "role" => "assistant", "content" => "answer"}),
                 "gemini"
               )

      assert [%{kind: :tool_use, id: "g1", name: "read_file", summary: "/tmp/x"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "tool_use",
                   "tool_id" => "g1",
                   "tool_name" => "read_file",
                   "parameters" => %{"file_path" => "/tmp/x"}
                 }),
                 "gemini"
               )

      assert [%{kind: :tool_result, tool_id: "g1", body: "contents", error?: false}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "tool_result",
                   "tool_id" => "g1",
                   "output" => "contents",
                   "status" => "success"
                 }),
                 "gemini"
               )

      assert [%{kind: :result, body: body}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "result",
                   "status" => "done",
                   "stats" => %{"duration_ms" => 800, "total_tokens" => 42}
                 }),
                 "gemini"
               )

      assert body == "done · 800ms · 42 tokens"
    end

    test "a failed tool result is marked as an error" do
      assert [%{kind: :tool_result, error?: true}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "tool_result",
                   "tool_id" => "g1",
                   "output" => "denied",
                   "status" => "error"
                 }),
                 "gemini"
               )
    end
  end

  describe "opencode (frozen)" do
    test "text, tool_use with and without input, step_finish" do
      assert [%{kind: :text, body: "hey"}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "text", "part" => %{"text" => "hey"}}),
                 "opencode"
               )

      assert [%{kind: :tool_use, name: "bash", summary: "pwd"}] =
               LegacyBlocks.from_line(
                 line(%{
                   "type" => "tool_use",
                   "part" => %{"tool" => "bash", "state" => %{"input" => %{"command" => "pwd"}}}
                 }),
                 "opencode"
               )

      assert [%{kind: :tool_use, name: "bash"}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "tool_use", "part" => %{"tool" => "bash"}}),
                 "opencode"
               )

      assert [%{kind: :result, body: "stop"}] =
               LegacyBlocks.from_line(
                 line(%{"type" => "step_finish", "part" => %{"reason" => "stop"}}),
                 "opencode"
               )
    end
  end

  describe "the raw fallback" do
    test "non-JSON stdout renders as a raw block, never disappears" do
      assert [%{kind: :raw, body: "npm WARN deprecated", summary: "raw"}] =
               LegacyBlocks.from_line("npm WARN deprecated", "claude")
    end

    test "an unclaimed JSON event keeps its type as the summary" do
      assert [%{kind: :raw, summary: "totally_new_event"}] =
               LegacyBlocks.from_line(line(%{"type" => "totally_new_event"}), "claude")
    end

    test "an unknown runtime falls back to raw rather than raising" do
      assert [%{kind: :raw}] = LegacyBlocks.from_line(line(%{"type" => "text"}), "somethingelse")
      assert [%{kind: :raw}] = LegacyBlocks.from_line(line(%{"type" => "text"}), nil)
    end
  end
end
