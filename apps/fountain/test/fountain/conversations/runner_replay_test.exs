defmodule Fountain.Conversations.RunnerReplayTest do
  use ExUnit.Case, async: true
  alias Fountain.Conversations.RunnerReplay

  test "old turns and permission requests are discarded before the active prompt boundary" do
    old =
      Jason.encode!(%{jsonrpc: "2.0", id: "old-permission", method: "session/request_permission"})

    boundary = Jason.encode!(%{jsonrpc: "2.0", id: 4, result: %{stopReason: "end_turn"}})

    active =
      Jason.encode!(%{
        jsonrpc: "2.0",
        id: "current-permission",
        method: "session/request_permission"
      }) <> "\n"

    wire = old <> "\n" <> boundary <> "\n" <> active

    for split <- 0..byte_size(wire) do
      <<first::binary-size(split), second::binary>> = wire
      assert {:ok, state, left} = RunnerReplay.feed(RunnerReplay.new(5), first)
      assert {:ok, nil, right} = RunnerReplay.feed(state, second)
      assert left <> right == active
    end
  end

  test "only a response with the preceding request ID opens the boundary" do
    request = Jason.encode!(%{jsonrpc: "2.0", id: 4, method: "session/request_permission"})
    wrong = Jason.encode!(%{jsonrpc: "2.0", id: 3, result: %{}})

    assert {:ok, state, ""} =
             RunnerReplay.feed(RunnerReplay.new(5), request <> "\n" <> wrong <> "\n")

    error = Jason.encode!(%{jsonrpc: "2.0", id: 4, error: %{code: -1}})
    assert {:ok, nil, "live"} = RunnerReplay.feed(state, error <> "\nlive")
  end

  test "a missing boundary cannot grow an unbounded partial line" do
    assert {:error, :runner_replay_line_too_large} =
             RunnerReplay.feed(RunnerReplay.new(5), :binary.copy("x", 4 * 1024 * 1024 + 1))
  end
end
