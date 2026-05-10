defmodule Fountain.Substitution do
  @moduledoc """
  `${VAR}` substitution for agent config (`mcp_servers`) at sprite
  provision time.

  Most MCP clients/servers don't expand env vars in their config — they
  read literal strings. So by default we substitute eagerly, before the
  config is written into the sprite. The escape exists for the rare
  case where a runtime _does_ do its own expansion and we want the ref
  to survive.

      ${VAR}    eager — substituted from the merged
                env_vars + env_secrets + vault_secrets map
      $${VAR}   escape — written through as literal `${VAR}`
      $$        literal `$`

  Identifiers must match `[A-Z_][A-Z0-9_]*` (UPPER_SNAKE_CASE), the
  same shape we already enforce on secret keys.

  Walks recursively through maps and lists; only string leaves are
  rewritten. Missing keys are accumulated into a single error so the
  user sees every typo in one provisioning attempt instead of finding
  them one at a time.

  Apply-time substitution (the same syntax, against a different vars
  source) lives in the Go CLI under `cli/internal/substitution`. Keep
  the two implementations behaviorally aligned.
  """

  @ref ~r/\$\$|\$\{([A-Z_][A-Z0-9_]*)\}/

  @type vars :: %{optional(String.t()) => String.t()}

  @spec apply(any(), vars()) :: {:ok, any()} | {:error, {:missing_vars, [String.t()]}}
  def apply(value, vars) do
    {result, missing} = walk(value, vars, [])

    case Enum.uniq(missing) do
      [] -> {:ok, result}
      list -> {:error, {:missing_vars, Enum.sort(list)}}
    end
  end

  defp walk(value, vars, missing) when is_binary(value) do
    new_missing = required_vars(value) |> Enum.reject(&Map.has_key?(vars, &1))

    result =
      if new_missing == [] do
        substitute_string(value, vars)
      else
        # Leave the original string alone when keys are missing; we'll
        # surface the error rather than producing a half-substituted
        # config that would be confusing to debug.
        value
      end

    {result, new_missing ++ missing}
  end

  defp walk(value, vars, missing) when is_map(value) do
    Enum.reduce(value, {%{}, missing}, fn {k, v}, {acc, m} ->
      {new_v, m2} = walk(v, vars, m)
      {Map.put(acc, k, new_v), m2}
    end)
  end

  defp walk(value, vars, missing) when is_list(value) do
    {rev, m} =
      Enum.reduce(value, {[], missing}, fn v, {acc, m} ->
        {new_v, m2} = walk(v, vars, m)
        {[new_v | acc], m2}
      end)

    {Enum.reverse(rev), m}
  end

  defp walk(value, _vars, missing), do: {value, missing}

  defp required_vars(s) do
    Regex.scan(@ref, s)
    |> Enum.reduce([], fn
      ["$$"], acc -> acc
      [_full, var], acc -> [var | acc]
    end)
  end

  defp substitute_string(s, vars) do
    Regex.replace(@ref, s, fn
      "$$", _ -> "$"
      _full, var -> Map.fetch!(vars, var)
    end)
  end
end
