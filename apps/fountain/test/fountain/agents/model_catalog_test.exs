defmodule Fountain.Agents.ModelCatalogTest do
  use ExUnit.Case, async: true

  alias Fountain.Agents.Agent
  alias Fountain.Agents.ModelCatalog

  # The suggestion list is Fountain's product data; the parser it is built on
  # is the library's (`Managoat.Runtimes.Model`, tested there). What is pinned
  # here is that the list and the changeset agree.

  test "providers/0 is the library's set, which is exactly what InferenceCredentials holds" do
    # The provider half is gated because this set is closed: it mirrors the
    # per-provider credential columns on InferenceCredentials.Credential
    # (anthropic_api_key / openai_api_key / gemini_api_key). Adding a provider
    # without a credential to export for it would put the old #554 bug back —
    # a sprite spawned with no inference key at all.
    assert ModelCatalog.providers() == ~w(anthropic openai google)
    assert ModelCatalog.providers() == Managoat.Runtimes.Model.providers()
  end

  test "suggestions/1 offers only the runtime's own provider" do
    for {runtime, provider} <- [
          {"claude", "anthropic"},
          {"codex", "openai"},
          {"gemini", "google"}
        ] do
      suggestions = ModelCatalog.suggestions(runtime)
      refute suggestions == []

      assert Enum.all?(suggestions, &String.starts_with?(&1, provider <> "/")),
             "#{runtime} was offered a foreign provider: #{inspect(suggestions)}"
    end
  end

  test "suggestions/1 offers every provider to opencode" do
    suggestions = ModelCatalog.suggestions("opencode")

    for provider <- ModelCatalog.providers() do
      assert Enum.any?(suggestions, &String.starts_with?(&1, provider <> "/"))
    end
  end

  test "every suggestion is a model the changeset accepts for its runtime" do
    for runtime <- Agent.runtimes(), model <- ModelCatalog.suggestions(runtime) do
      changeset =
        Agent.changeset(%Agent{}, %{name: "a", runtime: runtime, model: model})

      assert changeset.valid?,
             "#{runtime} suggestion #{model} is rejected: #{inspect(changeset.errors)}"
    end
  end

  # The ids the pinned ACP adapters refuse at `session/set_model`, with the
  # date each was observed. A refusal happens before a prompt is written, so
  # since #1640 it fails the turn outright — suggesting one of these is an
  # outage, not a stale hint. Every entry here was served happily by its
  # provider at the time it was refused, which is exactly why the provider
  # check alone did not catch it: see the two-gates note in `ModelCatalog`.
  #
  # Removing an entry is legitimate **after** an adapter pin moves and the
  # refusal rate for that id goes to zero on real turns. It is not legitimate
  # because the model works in a `curl` to the provider.
  @refused_by_pinned_adapters %{
    # claude-agent-acp 0.66.0 — "Invalid value for config option model".
    # 289 refusals for claude-sonnet-4-6 alone, 2026-08-16..2026-09-06.
    "anthropic/claude-sonnet-4-6" => "2026-09-06",
    "anthropic/claude-opus-4-7" => "2026-08-27",
    "anthropic/claude-opus-4-8" => "2026-08-23",
    # codex-acp 1.10.0 — "Invalid params". Refused after the #1640 bump that
    # added gpt-6-astra; it was accepted by 1.9.x.
    "openai/gpt-5.3-codex" => "2026-09-06",
    # Google retired it for new keys; opencode's adapter refused it too.
    "google/gemini-2.5-pro" => "2026-08-20"
  }

  test "no suggestion is an id the pinned adapters are known to refuse" do
    suggested =
      Agent.runtimes() |> Enum.flat_map(&ModelCatalog.suggestions/1) |> MapSet.new()

    for {model, observed} <- @refused_by_pinned_adapters do
      refute MapSet.member?(suggested, model),
             """
             #{model} is suggested again, but the pinned ACP adapter refused it \
             on #{observed}. A refusal fails the turn before any prompt is sent \
             (#1640), so this suggestion is an outage for every agent that takes \
             it. Confirm the adapter accepts it on a real turn before relisting.
             """
    end
  end

  test "known?/1 recognises catalog entries and nothing else" do
    assert ModelCatalog.known?("anthropic/claude-opus-5")
    # Right provider, unlisted id — accepted by the changeset, just not listed.
    refute ModelCatalog.known?("anthropic/claude-opus-99")
    # Listed id under the wrong provider.
    refute ModelCatalog.known?("openai/claude-opus-5")
    refute ModelCatalog.known?("bare-id")
    refute ModelCatalog.known?(nil)
  end
end
