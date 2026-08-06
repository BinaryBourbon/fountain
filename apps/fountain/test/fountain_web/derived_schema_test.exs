defmodule FountainWeb.DerivedSchemaTest do
  @moduledoc """
  `FountainWeb.DerivedSchema.build/1` — the derivation itself (issue #599).

  The published spec is covered elsewhere: `SchemaEnumGuardrailTest` checks
  every enum against its domain list, and `SchemasTest` pins the emitted JSON
  fields. These cover the mapping rules and, more importantly, the two failure
  modes — an unknown field and an unmappable column type — which must raise at
  compile time rather than silently producing a property-less schema.
  """

  use ExUnit.Case, async: true

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.{Conversation, Turn}
  alias FountainWeb.DerivedSchema
  alias OpenApiSpex.Schema

  defp props(opts) do
    opts
    |> Keyword.put_new(:title, "T")
    |> DerivedSchema.build()
    |> Map.fetch!(:properties)
  end

  describe "type derivation" do
    test "binary_id becomes a uuid-formatted string" do
      assert %{id: %Schema{type: :string, format: :uuid}} =
               props(source: Turn, expose: [:id])
    end

    test "an integer primary key stays an integer, without a format" do
      assert %{id: %Schema{type: :integer, format: nil}} =
               props(source: Fountain.Audit.Event, expose: [:id])
    end

    test "datetime columns become date-time strings" do
      assert %{inserted_at: %Schema{type: :string, format: :"date-time"}} =
               props(source: Turn, expose: [:inserted_at])
    end

    test "a map column becomes a free-form object" do
      assert %{metadata: %Schema{type: :object, additionalProperties: true}} =
               props(source: Agent, expose: [:metadata])
    end

    test "an array column derives its item schema from the inner type" do
      assert %{
               allowed_vault_ids: %Schema{
                 type: :array,
                 items: %Schema{type: :string, format: :uuid}
               }
             } = props(source: Agent, expose: [:allowed_vault_ids])
    end

    test "a virtual field resolves through virtual_type" do
      assert %{conversation_count: %Schema{type: :integer}} =
               props(source: Agent, expose: [:conversation_count])
    end
  end

  # Enums are deliberately NOT derived — see the moduledoc. Reading the list
  # from the domain module makes SchemaEnumGuardrailTest compare it against
  # itself, so a status added to the schema expands the published contract
  # with nothing failing. These pin that decision in place.
  describe "enums stay literal" do
    test "a literal list is carried onto the derived type" do
      assert %{status: %Schema{type: :string, enum: ~w(a b)}} =
               props(source: Conversation, expose: [{:status, enum: ~w(a b)}])
    end

    test "a function reference is refused, naming the guardrail it would defeat" do
      assert_raise ArgumentError, ~r/literal list.*compare it against itself/s, fn ->
        DerivedSchema.build(
          source: Conversation,
          title: "T",
          expose: [{:status, enum: {Conversation, :statuses}}]
        )
      end
    end

    test "a bare accessor atom is refused too" do
      assert_raise ArgumentError, ~r/literal list/, fn ->
        DerivedSchema.build(source: User, title: "T", expose: [{:role, enum: :roles}])
      end
    end
  end

  describe "annotations the schema module cannot know" do
    test "nullable, doc, pattern and example are carried through" do
      assert %{model: %Schema{nullable: true, description: "d", pattern: "^x$", example: "e"}} =
               props(
                 source: Agent,
                 expose: [{:model, nullable: true, doc: "d", pattern: "^x$", example: "e"}]
               )
    end

    test "schema: bypasses derivation entirely" do
      override = %Schema{oneOf: [], nullable: true}

      assert %{sandbox_id: ^override} =
               props(source: Conversation, expose: [{:sandbox_id, schema: override}])
    end

    test "extra: adds properties with no column behind them" do
      extra = %Schema{type: :boolean}

      assert %{id: %Schema{}, unread: ^extra} =
               props(source: Conversation, expose: [:id], extra: %{unread: extra})
    end
  end

  describe "build/1 shape" do
    test "description and required are omitted when not supplied" do
      built = DerivedSchema.build(source: Turn, title: "T", expose: [:id])

      refute Map.has_key?(built, :description)
      refute Map.has_key?(built, :required)
      assert built.type == :object
    end

    test "an empty required list is dropped rather than emitted" do
      built = DerivedSchema.build(source: Turn, title: "T", expose: [:id], required: [])
      refute Map.has_key?(built, :required)
    end
  end

  # The whole point of deriving is that the schema module is the source of
  # truth. If a field is renamed there, the OpenAPI schema must fail to
  # compile — not quietly drop the property, which would ship a spec that
  # no longer describes the response.
  describe "failure modes" do
    test "an unknown field raises, naming the source and the escape hatch" do
      assert_raise ArgumentError, ~r/has no field :nope.*schema:/s, fn ->
        DerivedSchema.build(source: Turn, title: "T", expose: [:nope])
      end
    end

    test "a column type with no OpenAPI mapping raises" do
      # :binary — a ciphertext column. Deliberately unmapped: there is no
      # correct wire representation, and guessing one could publish bytes.
      assert_raise ArgumentError, ~r/no OpenAPI mapping/, fn ->
        DerivedSchema.build(
          source: Fountain.InferenceCredentials.Credential,
          title: "T",
          expose: [:anthropic_api_key_ciphertext]
        )
      end
    end

    test "an unknown field option raises rather than being ignored" do
      assert_raise ArgumentError, ~r/unknown field option :nullible/, fn ->
        DerivedSchema.build(source: Turn, title: "T", expose: [{:id, nullible: true}])
      end
    end
  end
end
