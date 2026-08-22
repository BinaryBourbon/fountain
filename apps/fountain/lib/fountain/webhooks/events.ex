defmodule Fountain.Webhooks.Events do
  @moduledoc """
  The webhook event catalogue: which stage transitions become
  `conversation.<stage>.<status>`, and what an endpoint's filter may say.

  `Fountain.Conversations.publish_stage/4` is the single chokepoint every
  operationally meaningful outcome flows through, so hanging dispatch off it
  means a new lifecycle outcome cannot be added without subscribers seeing it.
  The list below is that guarantee written down: `webhook_events_test.exs`
  reads the `publish_stage/4` call sites out of the source and fails if one
  produces a type this module does not name.

  `kind: "output"` rows are deliberately absent. A chatty turn writes
  thousands of stdout chunks, and turning those into HTTP POSTs is a
  self-inflicted denial of service on both ends. Streaming output is what
  `GET /api/conversations/:id/events` is for.
  """

  # stage => the statuses that stage is published with.
  @catalogue [
    {"provision", ~w(started done failed)},
    {"clone", ~w(started done failed)},
    {"packages", ~w(started done failed)},
    {"network", ~w(started done failed)},
    {"setup", ~w(started done failed)},
    {"checkpoint_restore", ~w(started done failed)},
    {"reattach", ~w(started done failed interrupted)},
    {"turn", ~w(started done failed interrupted)},
    {"request", ~w(started done)},
    {"model", ~w(failed)},
    {"session", ~w(done)},
    {"sandbox", ~w(done)},
    {"terminate", ~w(done)}
  ]

  @types for {stage, statuses} <- @catalogue,
             status <- statuses,
             do: "conversation.#{stage}.#{status}"

  # What a new endpoint subscribes to when it names nothing. The three an
  # integrator almost always wants; everything else is opt-in.
  @defaults ~w(conversation.turn.done conversation.turn.failed conversation.provision.failed)

  @doc "Every event type this instance can emit, in catalogue order."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc "The catalogue as `{stage, statuses}` pairs — what the docs page renders."
  @spec catalogue() :: [{String.t(), [String.t()]}]
  def catalogue, do: @catalogue

  @doc "The default subscription for an endpoint that names no event types."
  @spec defaults() :: [String.t()]
  def defaults, do: @defaults

  @doc "The event type for a stage transition."
  @spec type(String.t(), String.t()) :: String.t()
  def type(stage, status), do: "conversation.#{stage}.#{status}"

  @doc "Whether `type` is in the catalogue."
  @spec known?(String.t()) :: boolean()
  def known?(type), do: type in @types

  @doc """
  Whether `entry` is something an endpoint may subscribe to.

  Three shapes: `"*"` (everything), a trailing wildcard over one stage
  (`"conversation.turn.*"`), or an exact type from the catalogue. A typo in
  an exact type is rejected at create time rather than silently subscribing
  to nothing.
  """
  @spec valid_filter?(term()) :: boolean()
  def valid_filter?("*"), do: true

  def valid_filter?(entry) when is_binary(entry) do
    case String.split(entry, ".") do
      ["conversation", stage, "*"] -> List.keymember?(@catalogue, stage, 0)
      _ -> known?(entry)
    end
  end

  def valid_filter?(_), do: false

  @doc "Whether an endpoint subscribing to `filters` wants `type`."
  @spec matches?([String.t()], String.t()) :: boolean()
  def matches?(filters, type) when is_list(filters) do
    Enum.any?(filters, &filter_matches?(&1, type))
  end

  defp filter_matches?("*", _type), do: true

  defp filter_matches?(filter, type) do
    case String.split(filter, ".") do
      ["conversation", stage, "*"] -> String.starts_with?(type, "conversation.#{stage}.")
      _ -> filter == type
    end
  end
end
