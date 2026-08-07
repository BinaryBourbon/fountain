defmodule Fountain.Runtimes.Model do
  @moduledoc """
  Translation between `agent.model` — always stored in canonical
  `provider/model_id` form — and what each runtime's CLI actually accepts.

  Only opencode is multi-provider: it takes the canonical string verbatim
  (`opencode run --model anthropic/claude-sonnet-4-6`) and reads the prefix
  to pick which API key to export. The other three CLIs each talk to one
  provider and want the bare id:

      claude --model claude-sonnet-4-6
      codex  --model gpt-5-codex        # also spelled -m
      gemini --model gemini-2.5-pro     # also spelled -m

  `Fountain.Agents.Agent` rejects a model whose prefix doesn't match its
  runtime at write time (via `provider_for_runtime/1`), so by the time a
  spawn reaches `build_command/5` stripping the prefix is always correct.
  Before #553 those three runtimes ignored the field entirely, so an
  `openai/gpt-5` agent on the claude runtime looked configured and quietly
  ran whatever the CLI defaulted to.

  This module also owns the curated model catalog (`suggestions/1`,
  `providers/0`) that the agent form offers and the changeset validates the
  provider half against — see the comment on `@catalog` for what is gated and
  what deliberately is not.
  """

  @provider_by_runtime %{
    "claude" => "anthropic",
    "codex" => "openai",
    "gemini" => "google"
  }

  # Curated, deliberately short suggestion list — newest first per provider.
  #
  # The *model id* half is never gated on this list: a model released after the
  # last deploy has to be usable the day it ships, so an unrecognised id is
  # accepted and passed to the CLI verbatim (the form says so; see #554). The
  # *provider* half is gated, because the set is not open — Fountain can only
  # export credentials for these three (`InferenceCredentials.Credential` has a
  # column per provider, and `OpenCode.default_env/2` maps exactly these three
  # prefixes). A typo like `anthopic/...` used to reach the sprite with no
  # inference credentials at all and fail as an auth error in the conversation
  # log; `Agent.changeset/2` now rejects it at write time.
  @catalog %{
    "anthropic" => ~w(
      claude-opus-5
      claude-sonnet-5
      claude-opus-4-8
      claude-sonnet-4-6
      claude-haiku-4-5
    ),
    "openai" => ~w(gpt-5-codex gpt-5),
    "google" => ~w(gemini-2.5-pro gemini-2.5-flash)
  }

  # Stable order for the UI: the single-provider runtimes in the order they
  # appear in @provider_by_runtime, so an opencode datalist reads the same way
  # every render.
  @provider_order ~w(anthropic openai google)

  @doc "Providers Fountain can export inference credentials for, in display order."
  def providers, do: @provider_order

  @doc "Whether `provider` is one Fountain can export credentials for."
  def known_provider?(provider), do: provider in @provider_order

  @doc """
  Suggested canonical `provider/model_id` strings for a runtime — the
  runtime's own provider for claude / codex / gemini, every provider for
  opencode (and for an unrecognised runtime, which the changeset rejects
  separately).

  These are suggestions, not an allowlist. `Agent.changeset/2` accepts any
  model id under a known provider.
  """
  def suggestions(runtime) do
    case provider_for_runtime(runtime) do
      nil -> Enum.flat_map(@provider_order, &suggestions_for_provider/1)
      provider -> suggestions_for_provider(provider)
    end
  end

  @doc "Whether a canonical model string is one of the curated suggestions."
  def known?(model) do
    case split(model) do
      {nil, nil} -> false
      {provider, id} -> id in Map.get(@catalog, provider, [])
    end
  end

  defp suggestions_for_provider(provider) do
    @catalog |> Map.fetch!(provider) |> Enum.map(&"#{provider}/#{&1}")
  end

  @doc """
  The single provider a runtime's CLI can reach, or `nil` for a
  multi-provider runtime (opencode) that accepts any prefix.
  """
  def provider_for_runtime(runtime) when is_binary(runtime),
    do: Map.get(@provider_by_runtime, runtime)

  def provider_for_runtime(_runtime), do: nil

  @doc """
  Split a canonical `provider/model_id` into its two halves.

  Returns `{nil, nil}` for anything not in canonical form — callers treat
  that as "no model to pass", never as something to guess at.
  """
  def split(model) when is_binary(model) do
    case String.split(model, "/", parts: 2) do
      [provider, id] when provider != "" and id != "" -> {provider, id}
      _ -> {nil, nil}
    end
  end

  def split(_model), do: {nil, nil}

  @doc "Provider half of a canonical model string, or `nil`."
  def provider(model), do: model |> split() |> elem(0)

  @doc "Model-id half of a canonical model string, or `nil`."
  def id(model), do: model |> split() |> elem(1)

  @doc """
  `["--model", "<bare id>"]` for the single-provider CLIs, or `[]` when the
  agent carries no parseable model. All three spell the long flag the same
  way, so one helper covers them.
  """
  def model_args(%{model: model}) do
    case id(model) do
      nil -> []
      id -> ["--model", id]
    end
  end

  def model_args(_agent), do: []
end
