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

  describe "the model catalog" do
    # The provider half is gated because this set is closed: it mirrors the
    # per-provider credential columns on InferenceCredentials.Credential
    # (anthropic_api_key / openai_api_key / gemini_api_key). Adding a provider
    # here without a credential to export for it would put the old #554 bug
    # back — a sprite spawned with no inference key at all.
    test "providers/0 is exactly the set Fountain can export credentials for" do
      assert Runtimes.Model.providers() == ~w(anthropic openai google)
    end

    test "known_provider?/1 accepts the three and nothing else" do
      assert Runtimes.Model.known_provider?("anthropic")
      assert Runtimes.Model.known_provider?("openai")
      assert Runtimes.Model.known_provider?("google")
      refute Runtimes.Model.known_provider?("anthopic")
      refute Runtimes.Model.known_provider?("openrouter")
      refute Runtimes.Model.known_provider?(nil)
    end

    test "suggestions/1 offers only the runtime's own provider" do
      for {runtime, provider} <- [
            {"claude", "anthropic"},
            {"codex", "openai"},
            {"gemini", "google"}
          ] do
        suggestions = Runtimes.Model.suggestions(runtime)
        refute suggestions == []

        assert Enum.all?(suggestions, &String.starts_with?(&1, provider <> "/")),
               "#{runtime} was offered a foreign provider: #{inspect(suggestions)}"
      end
    end

    test "suggestions/1 offers every provider to opencode" do
      suggestions = Runtimes.Model.suggestions("opencode")

      for provider <- Runtimes.Model.providers() do
        assert Enum.any?(suggestions, &String.starts_with?(&1, provider <> "/"))
      end
    end

    test "every suggestion is a model the changeset accepts for its runtime" do
      for runtime <- Agent.runtimes(), model <- Runtimes.Model.suggestions(runtime) do
        changeset =
          Agent.changeset(%Agent{}, %{name: "a", runtime: runtime, model: model})

        assert changeset.valid?,
               "#{runtime} suggestion #{model} is rejected: #{inspect(changeset.errors)}"
      end
    end

    test "known?/1 recognises catalog entries and nothing else" do
      assert Runtimes.Model.known?("anthropic/claude-opus-5")
      # Right provider, unlisted id — accepted by the changeset, just not listed.
      refute Runtimes.Model.known?("anthropic/claude-opus-99")
      # Listed id under the wrong provider.
      refute Runtimes.Model.known?("openai/claude-opus-5")
      refute Runtimes.Model.known?("bare-id")
      refute Runtimes.Model.known?(nil)
    end
  end

  describe "acp_model/2" do
    test "a single-provider runtime gets the bare id" do
      assert Runtimes.Model.acp_model("claude", "anthropic/claude-sonnet-4-6") ==
               "claude-sonnet-4-6"

      assert Runtimes.Model.acp_model("codex", "openai/gpt-5.3-codex") == "gpt-5.3-codex"
    end

    test "opencode gets the canonical id, the only name it knows a model by" do
      assert Runtimes.Model.acp_model("opencode", "anthropic/claude-sonnet-4-6") ==
               "anthropic/claude-sonnet-4-6"
    end

    test "no parseable model, nothing to pin" do
      assert Runtimes.Model.acp_model("opencode", "claude-sonnet-4-6") == nil
      assert Runtimes.Model.acp_model("claude", nil) == nil
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

  # The regression #553 describes: runtimes built argv that never mentioned
  # agent.model, so the CLI's own default ran instead.
  #
  # No runtime builds argv any more. gemini was the last one, and #941 deleted
  # its `build_command/5` along with the `--approval-mode yolo` it carried. The
  # model is pinned per session over ACP now — see "model selection" in
  # `acp/peer_test.exs`, which is where this regression is guarded.
  #
  # `Model.model_args/1` itself is still tested above: it is what an argv-based
  # runtime would use, and it is cheaper to keep than to re-derive if a fifth
  # runtime ever arrives that cannot speak ACP.
end
