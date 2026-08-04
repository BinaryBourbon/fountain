defmodule Fountain.Credo.Check.UnsafeCallOwnership do
  @moduledoc """
  Every remote call to a `_unsafe_*` function must carry a nearby comment
  containing the word "ownership" explaining which tenant-scoped fetch (or
  which structural property — admin surface, system sweep) establishes
  ownership. This automates the manual `_unsafe_` call-site sweeps
  (#328/#383); the policy itself lives in CLAUDE.md's tenant isolation
  section.

  Local calls (inside the module that defines the `_unsafe_` function) are
  not flagged — scoping is that context module's own concern, reviewed with
  the module.
  """

  use Credo.Check,
    id: "FN0001",
    base_priority: :high,
    category: :warning,
    param_defaults: [lookback: 10, exempt_paths: []],
    explanations: [
      check: """
      Functions prefixed `_unsafe_` bypass tenant scoping. A remote call to
      one is only legitimate when ownership of the fetched data is already
      established on that code path — by an adjacent tenant-scoped parent
      fetch, an admin-only surface, or a system-level process.

      Whichever it is, the call site must say so: a comment containing the
      word "ownership" within `lookback` lines above the call (or on the
      call's own line). One comment covers every `_unsafe_` call in the
      window below it, so clustered calls need only one.

          # ownership: established by the scoped get_vault/2 above
          secrets = Vaults._unsafe_list_secrets(vault)

      Files whose path matches `exempt_paths` (GenServers that establish
      ownership at init, system sweeps, tests) are skipped entirely.
      """,
      params: [
        lookback: "How many lines above a call to search for an ownership comment.",
        exempt_paths:
          "Path fragments; files matching any of them may call `_unsafe_` functions uncommented."
      ]
    ]

  @ownership_comment ~r/#.*ownership/i

  @impl true
  def run(%SourceFile{} = source_file, params) do
    exempt = Params.get(params, :exempt_paths, __MODULE__)

    if Enum.any?(exempt, &String.contains?(source_file.filename, &1)) do
      []
    else
      issue_meta = IssueMeta.for(source_file, params)
      lookback = Params.get(params, :lookback, __MODULE__)
      lines = source_file |> SourceFile.lines() |> Map.new()

      source_file
      |> Credo.Code.prewalk(&traverse/2, [])
      |> Enum.reject(fn {line_no, _fun} -> justified?(line_no, lines, lookback) end)
      |> Enum.map(fn {line_no, fun} ->
        format_issue(issue_meta,
          message:
            "Remote call to #{fun}/? bypasses tenant scoping — add a `# ownership: ...` " <>
              "comment (within #{lookback} lines above) naming what establishes ownership here.",
          trigger: to_string(fun),
          line_no: line_no
        )
      end)
    end
  end

  # Remote calls only: `Mod._unsafe_x(...)`, `__MODULE__._unsafe_x(...)` and
  # remote captures `&Mod._unsafe_x/1`. Local calls and the `def` of the
  # function itself never produce a dot node, so they fall through.
  defp traverse({{:., _, [_mod, fun]}, meta, args} = ast, acc)
       when is_atom(fun) and is_list(args) do
    if unsafe?(fun) do
      {ast, [{meta[:line], fun} | acc]}
    else
      {ast, acc}
    end
  end

  defp traverse(ast, acc), do: {ast, acc}

  defp unsafe?(fun), do: String.starts_with?(Atom.to_string(fun), "_unsafe_")

  defp justified?(line_no, lines, lookback) do
    Enum.any?(max(1, line_no - lookback)..line_no, fn n ->
      case lines[n] do
        nil -> false
        text -> text =~ @ownership_comment
      end
    end)
  end
end
