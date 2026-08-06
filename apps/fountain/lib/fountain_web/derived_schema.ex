defmodule FountainWeb.DerivedSchema do
  @moduledoc """
  Build an OpenAPI schema from the Ecto schema it describes (issue #599).

  `FountainWeb.Schemas` restated the domain model by hand: field names,
  types, `format: :uuid`, and `date-time`, all of which are already declared
  once in the schema module. This derives them instead, so a renamed or
  retyped column fails the build rather than publishing a spec that no longer
  describes the response.

      defmodule Turn do
        use FountainWeb.DerivedSchema,
          source: Fountain.Conversations.Turn,
          title: "Turn",
          description: "One prompt → exit_code cycle within a conversation.",
          expose: [
            :id,
            :turn_number,
            :prompt,
            {:status, enum: :statuses},
            {:exit_code, nullable: true},
            {:started_at, nullable: true}
          ],
          required: [:id, :turn_number, :prompt, :status]
      end

  ## What is derived, and what is not

  Derived from `__schema__/1,2`: the property's `type`, plus `format: :uuid`
  for `:binary_id` and `format: :"date-time"` for the datetime types, and the
  `items` shape of an array column. Virtual fields resolve through
  `__schema__(:virtual_type, field)`, so a computed count needs no
  annotation beyond being listed.

  Not derived, because the schema module does not know it:

    * **`nullable`** — nullability lives in the migration, not the schema.
    * **`required`** — `validate_required` is about writes; OpenAPI
      `required` is about what a *response* guarantees. Different lists,
      deliberately kept separate.
    * **descriptions** — `doc:` carries knowledge that exists nowhere else
      and must survive derivation. Losing it would make the spec worse.

  ## Why enums are NOT derived

  `enum:` takes a literal list. Reading it from `Conversation.statuses/0`
  was tried and reverted, because it quietly removed the check that
  motivated #599 in the first place.

  With the list read from the domain module, adding a status makes the
  published spec grow a value on its own, and
  `FountainWeb.SchemaEnumGuardrailTest` compares that value against itself
  and passes. Measured on the branch that did it: the same injected drift
  that fails loudly with literal enums produced a green suite and a silently
  expanded API contract.

  So the duplication here is deliberate. Duplication was never the problem —
  *undetected divergence* was, and the guardrail test covers that at a
  fraction of the cost. Enum membership is a contract decision that should
  cost someone a deliberate edit; a column's type is not.

  ## Field options

    * `enum: ~w(a b c)` — a literal list, checked against the domain list by
      the guardrail test. See "Why enums are NOT derived" above.
    * `nullable: true`
    * `doc: "..."` — the property description.
    * `pattern: "..."`, `format: :uuid`, `example: ...`
    * `items: %Schema{}` — replace a derived array's item schema.
    * `additional_properties:` / `properties:` — refine a derived `:map`
      column, whose value shape the schema module does not record.
    * `schema: %Schema{}` — bypass derivation entirely for one field, for a
      shape richer than a column type can express.

  `extra:` adds properties with no column behind them — fields a JSON view
  computes (`image_count`) or renames (`ts` from `inserted_at`).

  Enum values are stringified, so an atom-typed domain list (`Credential`
  keeps providers as atoms) lands on the wire as strings.

  `FountainWeb.SchemaEnumGuardrailTest` still checks every enum in the
  published spec against its domain list — including the ones this module
  derives, which is what keeps a hand-written schema next to a derived one
  from drifting unnoticed.
  """

  alias OpenApiSpex.Schema

  defmacro __using__(opts) do
    quote do
      require OpenApiSpex
      OpenApiSpex.schema(FountainWeb.DerivedSchema.build(unquote(opts)))
    end
  end

  @doc """
  Build the schema map `OpenApiSpex.schema/1` expects.

  Called at compile time from the `__using__/1` expansion; also usable
  directly by a schema that needs to post-process the result.
  """
  def build(opts) do
    source = Keyword.fetch!(opts, :source)

    properties =
      opts
      |> Keyword.get(:expose, [])
      |> Map.new(fn field ->
        {name, field_opts} = split_field(field)
        {name, property(source, name, field_opts)}
      end)
      |> Map.merge(Keyword.get(opts, :extra, %{}))

    %{title: Keyword.fetch!(opts, :title), type: :object, properties: properties}
    |> maybe_put(:description, Keyword.get(opts, :description))
    |> maybe_put(:required, presence(Keyword.get(opts, :required, [])))
  end

  defp split_field(name) when is_atom(name), do: {name, []}
  defp split_field({name, field_opts}) when is_atom(name), do: {name, field_opts}

  defp property(source, name, field_opts) do
    case Keyword.fetch(field_opts, :schema) do
      {:ok, %Schema{} = override} -> override
      :error -> source |> derive_type!(name) |> decorate(field_opts)
    end
  end

  defp derive_type!(source, name) do
    case ecto_type(source, name) do
      nil ->
        raise ArgumentError,
              "#{inspect(source)} has no field #{inspect(name)} — " <>
                "add it to the schema, or declare the property with `schema:`"

      type ->
        type_schema(type) ||
          raise ArgumentError,
                "no OpenAPI mapping for #{inspect(source)}.#{name} of type #{inspect(type)} — " <>
                  "declare the property with `schema:`"
    end
  end

  defp ecto_type(source, name) do
    source.__schema__(:type, name) || source.__schema__(:virtual_type, name)
  end

  defp type_schema(:binary_id), do: %Schema{type: :string, format: :uuid}
  defp type_schema(:id), do: %Schema{type: :integer}
  defp type_schema(:string), do: %Schema{type: :string}
  defp type_schema(:integer), do: %Schema{type: :integer}
  defp type_schema(:boolean), do: %Schema{type: :boolean}
  defp type_schema(:float), do: %Schema{type: :number}
  defp type_schema(:decimal), do: %Schema{type: :string}
  defp type_schema(:map), do: %Schema{type: :object, additionalProperties: true}
  defp type_schema({:map, _}), do: %Schema{type: :object, additionalProperties: true}

  defp type_schema(t) when t in [:utc_datetime, :utc_datetime_usec, :naive_datetime],
    do: %Schema{type: :string, format: :"date-time"}

  defp type_schema({:array, inner}) do
    case type_schema(inner) do
      nil -> nil
      items -> %Schema{type: :array, items: items}
    end
  end

  defp type_schema(_), do: nil

  # Order matters only for readability; each clause sets an independent field.
  defp decorate(%Schema{} = schema, field_opts) do
    Enum.reduce(field_opts, schema, fn
      {:enum, values}, acc -> %{acc | enum: enum_literal!(values)}
      {:nullable, value}, acc -> %{acc | nullable: value}
      {:doc, text}, acc -> %{acc | description: text}
      {:pattern, p}, acc -> %{acc | pattern: p}
      {:format, f}, acc -> %{acc | format: f}
      {:example, e}, acc -> %{acc | example: e}
      {:items, i}, acc -> %{acc | items: i}
      {:additional_properties, a}, acc -> %{acc | additionalProperties: a}
      {:properties, p}, acc -> %{acc | properties: p}
      {:schema, _}, acc -> acc
      {key, _}, _acc -> raise ArgumentError, "unknown field option #{inspect(key)}"
    end)
  end

  # A literal list, never a call into the domain module — see the moduledoc.
  defp enum_literal!(values) when is_list(values), do: values

  defp enum_literal!(other) do
    raise ArgumentError,
          "enum: takes a literal list of values, got #{inspect(other)}. " <>
            "Reading the list from the domain module would make " <>
            "FountainWeb.SchemaEnumGuardrailTest compare it against itself."
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp presence([]), do: nil
  defp presence(list), do: list
end
