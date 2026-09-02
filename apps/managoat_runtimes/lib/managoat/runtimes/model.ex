defmodule Managoat.Runtimes.Model do
  @moduledoc """
  Translation between an agent's `model` — always stored in canonical
  `provider/model_id` form — and what each runtime's CLI actually accepts.

  Only opencode is multi-provider: it takes the canonical string verbatim
  (`opencode run --model anthropic/claude-sonnet-4-6`) and reads the prefix
  to pick which API key to export. The other three CLIs each talk to one
  provider and want the bare id:

      claude --model claude-sonnet-4-6
      codex  --model gpt-5.3-codex      # also spelled -m
      gemini --model gemini-3.1-pro-preview   # also spelled -m

  A host rejects a model whose prefix doesn't match its runtime at write
  time (via `provider_for_runtime/1`), so by the time a spawn reaches
  `build_command/5` stripping the prefix is always correct. Before that check
  existed those three runtimes ignored the field entirely, so an
  `openai/gpt-5` agent on the claude runtime looked configured and quietly
  ran whatever the CLI defaulted to.

  This is the parser only. Which models to *suggest* for a runtime is product
  data that changes with every provider release, and it stays with the host
  (in Fountain, the `Agents.ModelCatalog` module, whose rule is "suggestions,
  not an allowlist": any id under a known provider is accepted).
  """

  @provider_by_runtime %{
    "claude" => "anthropic",
    "codex" => "openai",
    "gemini" => "google"
  }

  # Stable order for a UI: the single-provider runtimes in the order they
  # appear in @provider_by_runtime, so an opencode datalist reads the same way
  # every render.
  @provider_order ~w(anthropic openai google)

  @doc """
  The providers the bundled runtimes can be handed a credential for, in
  display order.

  The set is closed because `OpenCode.default_env/2` maps exactly these three
  prefixes to an env var, and claude, codex and gemini each reach one of
  them. A typo like `anthopic/...` would otherwise reach the sandbox with no
  inference credential at all and fail as an auth error in the conversation
  log; a host gates the provider half of a model on `known_provider?/1` at
  write time for that reason.
  """
  def providers, do: @provider_order

  @doc "Whether `provider` is one the bundled runtimes can be given a credential for."
  def known_provider?(provider), do: provider in @provider_order

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

  @doc """
  The id to pin over ACP (`session/set_model` or the `model` config option).

  A single-provider runtime names its models bare (`claude-sonnet-4-6`); a
  multi-provider one (opencode) only knows them by the canonical
  `provider/model_id`, and a bare id is "model not found" there — after which
  opencode quietly falls back to its own default over its own gateway, and
  the provider the tenant configured is never called. Measured live on
  2026-08-25 with the egress broker's log in front of it.
  """
  def acp_model(runtime, model) when is_binary(runtime) do
    case {provider_for_runtime(runtime), split(model)} do
      {_, {nil, nil}} -> nil
      {nil, _} -> model
      {_provider, {_, id}} -> id
    end
  end

  def acp_model(_runtime, model), do: id(model)
end
