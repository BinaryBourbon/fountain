defmodule Fountain.ContractTest do
  use ExUnit.Case, async: true

  @sdk "elixir"

  test "declared wire dependencies still match the server contract" do
    contract_dir = Path.expand("../../contract", __DIR__)

    contract =
      contract_dir
      |> Path.join("contract.json")
      |> File.read!()
      |> Jason.decode!()

    manifest =
      contract_dir
      |> Path.join("manifests/elixir.json")
      |> File.read!()
      |> Jason.decode!()

    problems =
      operation_problems(contract, manifest) ++
        schema_problems(contract, manifest) ++ enum_problems(contract, manifest)

    if problems != [] do
      rendered =
        Enum.map_join(problems, "\n\n", fn {scenario, detail} ->
          "  #{scenario}\n      #{detail}"
        end)

      flunk(
        "SDK contract check FAILED for #{@sdk} (#{length(problems)} problems)\n\n" <>
          rendered <>
          "\n\nThe server's wire contract moved. Update sdk/elixir to match, then\n" <>
          "adjust sdk/contract/manifests/elixir.json. See sdk/contract/README.md."
      )
    end

    assert problems == []
  end

  defp operation_problems(contract, manifest) do
    operations = Map.get(contract, "operations", %{})

    manifest
    |> Map.get("operations", [])
    |> Enum.flat_map(fn operation ->
      if Map.has_key?(operations, operation) do
        []
      else
        [
          {"operation #{operation}",
           "the API no longer serves it. Update the client, or drop it from the manifest."}
        ]
      end
    end)
  end

  defp schema_problems(contract, manifest) do
    schemas = Map.get(contract, "schemas", %{})

    manifest
    |> Map.get("schemas", %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {name, declared} ->
      case Map.get(schemas, name) do
        nil ->
          [{"schema #{name}", "the API no longer defines it."}]

        schema ->
          properties = Map.get(schema, "properties", %{})

          check_fields(name, properties, Map.get(declared, "required", []), "required") ++
            check_fields(name, properties, Map.get(declared, "optional", []), "optional") ++
            check_fields(name, properties, Map.get(declared, "fields", []), "present")
      end
    end)
  end

  defp check_fields(name, properties, fields, expectation) do
    Enum.flat_map(fields, fn field ->
      case Map.fetch(properties, field) do
        :error ->
          available = properties |> Map.keys() |> Enum.sort() |> Enum.join(", ")

          [
            {"#{name}.#{field}", "the API no longer has this property. It has: #{available}"}
          ]

        {:ok, property} ->
          cond do
            expectation == "required" and property["required"] != true ->
              [
                {"#{name}.#{field}",
                 "this client reads it as always present, but the API no longer requires it."}
              ]

            expectation == "optional" and property["required"] == true ->
              [
                {"#{name}.#{field}", "this client omits it, but the API now requires it."}
              ]

            true ->
              []
          end
      end
    end)
  end

  defp enum_problems(contract, manifest) do
    schemas = Map.get(contract, "schemas", %{})

    manifest
    |> Map.get("enums", %{})
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {path, declared} ->
      [name, field] = String.split(path, ".", parts: 2)
      property = get_in(schemas, [name, "properties", field])

      cond do
        is_nil(property) ->
          [{"enum #{path}", "the API no longer has this property."}]

        not is_list(property["enum"]) ->
          [{"enum #{path}", "the API no longer constrains this property to an enum."}]

        true ->
          values = if is_list(declared), do: declared, else: Map.get(declared, "values", [])
          accepted = property["enum"]
          missing = Enum.reject(values, &(&1 in accepted))

          missing_problems =
            if missing == [] do
              []
            else
              [
                {"enum #{path}",
                 "this client handles #{Enum.join(missing, ", ")}, which the API no longer accepts. " <>
                   "It now accepts: #{Enum.join(accepted, ", ")}"}
              ]
            end

          extra_problems =
            if is_map(declared) and declared["exhaustive"] == true do
              extra = Enum.reject(accepted, &(&1 in values))

              if extra == [] do
                []
              else
                [
                  {"enum #{path}",
                   "this client claims to handle every value but the API added: #{Enum.join(extra, ", ")}"}
                ]
              end
            else
              []
            end

          missing_problems ++ extra_problems
      end
    end)
  end
end
