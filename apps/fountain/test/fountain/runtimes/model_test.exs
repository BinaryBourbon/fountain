defmodule Fountain.Runtimes.ModelTest do
  use ExUnit.Case, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Runtimes

  defp agent(runtime, model), do: %Agent{name: "a", runtime: runtime, model: model}

  describe "provider_for_runtime/1" do
    test "maps each single-provider runtime to its provider" do
      assert Runtimes.Model.provider_for_runtime("claude") == "anthropic"
      assert Runtimes.Model.provider_for_runtime("codex") == "openai"
      assert Runtimes.Model.provider_for_runtime("gemini") == "google"
    end

    test "returns nil for opencode — it is multi-provider" do
      assert Runtimes.Model.provider_for_runtime("opencode") == nil
    end

    test "returns nil for anything unrecognised" do
      assert Runtimes.Model.provider_for_runtime("nope") == nil
      assert Runtimes.Model.provider_for_runtime(nil) == nil
    end
  end

  describe "split/1" do
    test "splits a canonical model on the first slash only" do
      assert Runtimes.Model.split("anthropic/claude-sonnet-4-6") ==
               {"anthropic", "claude-sonnet-4-6"}

      assert Runtimes.Model.split("openrouter/meta/llama-3") == {"openrouter", "meta/llama-3"}
    end

    test "refuses to guess at anything non-canonical" do
      for bad <- ["claude-sonnet-4-6", "anthropic/", "/gpt-5", "", nil] do
        assert Runtimes.Model.split(bad) == {nil, nil}
      end
    end
  end

  describe "model_args/1" do
    test "strips the provider prefix" do
      assert Runtimes.Model.model_args(agent("claude", "anthropic/claude-sonnet-4-6")) ==
               ["--model", "claude-sonnet-4-6"]
    end

    test "passes no flag when there is no parseable model" do
      assert Runtimes.Model.model_args(agent("claude", nil)) == []
      assert Runtimes.Model.model_args(agent("claude", "bare-id")) == []
      assert Runtimes.Model.model_args(%{}) == []
    end
  end

  # The regression #553 describes: three of four runtimes built argv that
  # never mentioned agent.model, so the CLI's own default ran instead.
  describe "build_command/5 honours agent.model" do
    test "claude passes the bare id" do
      {"claude", argv, _opts} =
        Runtimes.Claude.build_command(
          agent("claude", "anthropic/claude-opus-4-7"),
          "hi",
          :run,
          "sess-1",
          []
        )

      assert "--model" in argv
      assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1) == "claude-opus-4-7"
      refute "anthropic/claude-opus-4-7" in argv
    end

    test "codex passes the bare id" do
      {"codex", argv, _opts} =
        Runtimes.Codex.build_command(agent("codex", "openai/gpt-5-codex"), "hi", :run, nil, [])

      assert "--model" in argv
      assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1) == "gpt-5-codex"
    end

    test "gemini passes the bare id" do
      {"gemini", argv, _opts} =
        Runtimes.Gemini.build_command(
          agent("gemini", "google/gemini-2.5-pro"),
          "hi",
          :run,
          nil,
          []
        )

      assert "--model" in argv
      assert Enum.at(argv, Enum.find_index(argv, &(&1 == "--model")) + 1) == "gemini-2.5-pro"
    end

    test "opencode still passes the canonical string verbatim" do
      {"opencode", argv, _opts} =
        Runtimes.OpenCode.build_command(
          agent("opencode", "anthropic/claude-sonnet-4-6"),
          "hi",
          :run,
          nil,
          []
        )

      assert "anthropic/claude-sonnet-4-6" in argv
    end

    test "the model survives a continue turn too" do
      {"claude", argv, _opts} =
        Runtimes.Claude.build_command(
          agent("claude", "anthropic/claude-opus-4-7"),
          "hi",
          :continue,
          "sess-1",
          []
        )

      assert "claude-opus-4-7" in argv
      assert "--resume" in argv
    end
  end
end
