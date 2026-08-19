defmodule Fountain.Runtimes.ACP.UsageTest do
  use ExUnit.Case, async: true

  alias Fountain.Runtimes.ACP.Usage

  test "the `usage` object, with the cache fields when present" do
    assert Usage.from_prompt_result(%{
             "stopReason" => "end_turn",
             "usage" => %{
               "inputTokens" => 10,
               "outputTokens" => 4,
               "cachedReadTokens" => 8,
               "cachedWriteTokens" => nil,
               "totalTokens" => 22
             }
           }) == %{"input" => 10, "output" => 4, "cache_read" => 8}
  end

  test "falls back to _meta.inputTokens / outputTokens" do
    assert Usage.from_prompt_result(%{"_meta" => %{"inputTokens" => 3, "outputTokens" => "7"}}) ==
             %{"input" => 3, "output" => 7}
  end

  test "nil when nothing is reported, or nothing usable" do
    assert Usage.from_prompt_result(%{"stopReason" => "end_turn"}) == nil
    assert Usage.from_prompt_result(%{"_meta" => %{"other" => 1}}) == nil
    assert Usage.from_prompt_result(%{"usage" => %{"inputTokens" => -1}}) == nil
    assert Usage.from_prompt_result(%{"usage" => %{"inputTokens" => true}}) == nil
    assert Usage.from_prompt_result(nil) == nil
  end

  test "one side missing counts as zero for that side" do
    assert Usage.from_prompt_result(%{"usage" => %{"outputTokens" => 5.0}}) ==
             %{"input" => 0, "output" => 5}
  end
end
