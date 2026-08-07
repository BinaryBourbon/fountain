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
  """

  @provider_by_runtime %{
    "claude" => "anthropic",
    "codex" => "openai",
    "gemini" => "google"
  }

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
