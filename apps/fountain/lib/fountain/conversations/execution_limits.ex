defmodule Fountain.Conversations.ExecutionLimits do
  @moduledoc """
  Typed per-turn policy, independent of provider-operation state.

  Host and account maps are ceilings. Every configured ceiling is inherited;
  omitting a request, an empty map, or an omitted field never disables one.
  A launch request may tighten the effective ceiling, never widen it. Explicit
  null fields, numeric strings, unknown keys and duplicate atom/string keys are
  invalid. Clearing an operator ceiling is outside the launch/resume request path.

  Callers supply a conversation's saved launch allowance. A new turn
  intersects that allowance with current host/account ceilings; a policy
  change can tighten future turns, but cannot grant an existing conversation a
  larger allowance. Recovery must reuse the original turn's persisted deadline
  and SDK limits rather than call this resolver to create another allowance.

  SDK request/dollar limits apply to a supported SDK Query, not a durable spend
  ledger. They do not bound blocked tools, work already in flight, or billed cost.
  The transport must separately prove support for every resolved control before
  admitting work. This module alone does not enable execution-limit enforcement.
  """

  @keys ~w(wall_time_seconds max_model_turns max_estimated_cost_usd)
  @atoms [:wall_time_seconds, :max_model_turns, :max_estimated_cost_usd]
  @key_map Map.new(Enum.zip(@atoms, @keys))
  @max_safe_integer 9_007_199_254_740_991
  # A wire-format bound, not a default allowance. Keeps deadline arithmetic
  # representable and leaves actual allowances to the host/account policy.
  @max_wall_seconds 31_536_000

  @type t :: %{optional(String.t()) => pos_integer() | float()}
  @type error :: {:execution_limits_invalid, String.t()} | {:execution_limits_widen, String.t()}

  def keys, do: @keys
  def max_wall_seconds, do: @max_wall_seconds

  @doc """
  The deployment-wide ceiling every account and launch is intersected with.

  Read from application env on each call rather than cached, so an operator
  raising or lowering it reaches a running node's next turn instead of its next
  restart. `%{}` — the default — is no ceiling, not a zero allowance.
  """
  @spec host_ceiling() :: t()
  def host_ceiling, do: Application.get_env(:fountain, :execution_limit_ceiling, %{})

  @doc """
  Controls the integrated runtime transport actually enforces, per runtime.

  Empty, deliberately, and this is the single place that says so. Admission
  passes it to `require_controls/2`, which is what turns a configured ceiling
  into `422 execution_limits_unsupported` rather than a promise nothing keeps.
  Naming it here means the PR that first enforces a control changes one
  function, and every door follows — rather than three call sites each passing
  their own `[]` and one of them being forgotten.
  """
  @spec enforced_controls(String.t() | nil) :: [String.t()]
  def enforced_controls(_runtime), do: []

  @doc "Parse the operator's JSON environment setting without echoing its input."
  def from_json_env(value) when value in [nil, ""], do: {:ok, %{}}

  def from_json_env(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, attrs} when is_map(attrs) -> normalize(attrs)
      {:ok, _} -> invalid("object_required")
      {:error, _} -> invalid("invalid_json")
    end
  end

  @doc "Normalize API or internal fields to the durable JSON representation."
  @spec normalize(term()) :: {:ok, t()} | {:error, error()}
  def normalize(nil), do: {:ok, %{}}

  def normalize(attrs) when is_map(attrs) and not is_struct(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      field = if key in @keys, do: key, else: Map.get(@key_map, key)

      cond do
        is_nil(field) -> {:halt, invalid("unknown_field")}
        Map.has_key?(normalized, field) -> {:halt, invalid("duplicate_field")}
        not valid_value?(field, value) -> {:halt, invalid(field)}
        true -> {:cont, {:ok, Map.put(normalized, field, value)}}
      end
    end)
  end

  def normalize(_), do: invalid("object_required")

  @doc "Resolve a launch request against all configured host/account ceilings."
  @spec resolve(term(), term(), term()) :: {:ok, t()} | {:error, error()}
  def resolve(host, account, request) do
    with {:ok, ceilings} <- intersect(host, account),
         {:ok, requested} <- normalize(request),
         :ok <- check_narrows(ceilings, requested) do
      {:ok, Map.merge(ceilings, requested)}
    end
  end

  @doc "Tighten an existing allowance without creating a fresh recovery budget."
  @spec for_new_turn(term(), term(), term()) :: {:ok, t()} | {:error, error()}
  def for_new_turn(host, account, launch_allowance) do
    with {:ok, ceilings} <- intersect(host, account) do
      intersect(ceilings, launch_allowance)
    end
  end

  @doc "A channel resume may narrow the saved allowance, never clear or widen it."
  @spec for_resume(term(), term(), term(), term()) :: {:ok, t()} | {:error, error()}
  def for_resume(host, account, launch_allowance, request) do
    with {:ok, allowance} <- for_new_turn(host, account, launch_allowance),
         {:ok, requested} <- normalize(request),
         :ok <- check_narrows(allowance, requested) do
      {:ok, Map.merge(allowance, requested)}
    end
  end

  @doc "Refuse every control the actual transport/runtime cannot enforce."
  @spec require_controls(t(), [String.t()]) ::
          :ok | {:error, {:execution_limits_unsupported, [String.t()]}}
  def require_controls(limits, supported) do
    missing = @keys |> Enum.filter(&(Map.has_key?(limits, &1) and &1 not in supported))
    if missing == [], do: :ok, else: {:error, {:execution_limits_unsupported, missing}}
  end

  @doc "The two allowlisted SDK fields, converted without creating atoms from input."
  @spec sdk_options(t()) :: map() | nil
  def sdk_options(limits) do
    options =
      for {atom, field} <- @key_map,
          field != "wall_time_seconds",
          Map.has_key?(limits, field),
          into: %{},
          do: {atom, Map.fetch!(limits, field)}

    if options == %{}, do: nil, else: options
  end

  defp intersect(left, right) do
    with {:ok, left} <- normalize(left),
         {:ok, right} <- normalize(right) do
      {:ok, Map.merge(left, right, fn _, a, b -> min(a, b) end)}
    end
  end

  defp check_narrows(ceilings, requested) do
    case Enum.find(@keys, fn key ->
           Map.has_key?(ceilings, key) and Map.has_key?(requested, key) and
             requested[key] > ceilings[key]
         end) do
      nil -> :ok
      field -> {:error, {:execution_limits_widen, field}}
    end
  end

  defp valid_value?("wall_time_seconds", value),
    do: is_integer(value) and value > 0 and value <= @max_wall_seconds

  defp valid_value?("max_model_turns", value),
    do: is_integer(value) and value > 0 and value <= @max_safe_integer

  defp valid_value?("max_estimated_cost_usd", value),
    do: is_number(value) and value > 0 and value <= @max_safe_integer

  defp invalid(field), do: {:error, {:execution_limits_invalid, field}}
end
