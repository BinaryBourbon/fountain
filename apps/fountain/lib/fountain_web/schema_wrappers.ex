defmodule FountainWeb.SchemaWrappers do
  @moduledoc """
  Declare the `%{data: ...}` envelope schemas every JSON collection uses.

  Twenty-two modules in `FountainWeb.Schemas` said nothing but "this response
  is one X" or "this response is a list of X", in nine lines each, and not
  even consistently — `ConversationListResponse` spelled across three lines
  what `TurnListResponse` said in one. They carry no knowledge: one
  description among the twenty-two.

      list_response(ConversationListResponse, of: Conversation)
      item_response(ConversationResponse, of: Conversation)

  `description:` is accepted for the rare envelope that has something to say.

  ## Scope

  Only the pure envelopes. The three paginated responses
  (`AdminUserListResponse`, `LogEventListResponse`, `AuditEventListResponse`)
  stay hand-written: they carry a `meta` block, and the API has two
  pagination idioms — cursor (`limit`/`has_more`/`next_cursor`) and offset
  (`page`/`per_page`/`total`). Folding those in would harden a choice between
  them that nobody has made yet, so it is deliberately left alone.

  ## Definition order still matters

  These expand to real `defmodule`s nested in `FountainWeb.Schemas`, so the
  item module must already be defined above the call — the implicit alias a
  nested `defmodule` creates only exists after it. That constraint predates
  this macro and is unchanged by it; `AdminAuditListResponse` still passes a
  fully qualified name because `AuditEvent` is defined further down the file.
  """

  @doc "Define a `%{data: [item]}` response schema module."
  defmacro list_response(name, opts) do
    item = Keyword.fetch!(opts, :of)
    description = Keyword.get(opts, :description)

    quote do
      defmodule unquote(name) do
        @moduledoc false
        require OpenApiSpex

        OpenApiSpex.schema(
          FountainWeb.SchemaWrappers.envelope(
            __MODULE__,
            %OpenApiSpex.Schema{type: :array, items: unquote(item)},
            unquote(description)
          )
        )
      end
    end
  end

  @doc "Define a `%{data: item}` response schema module."
  defmacro item_response(name, opts) do
    item = Keyword.fetch!(opts, :of)
    description = Keyword.get(opts, :description)

    quote do
      defmodule unquote(name) do
        @moduledoc false
        require OpenApiSpex

        OpenApiSpex.schema(
          FountainWeb.SchemaWrappers.envelope(__MODULE__, unquote(item), unquote(description))
        )
      end
    end
  end

  @doc """
  Build the envelope map `OpenApiSpex.schema/1` expects.

  The title is the module's own last segment, which is what all twenty-two
  hand-written envelopes used.
  """
  def envelope(module, data_schema, description) do
    envelope = %{
      title: module |> Module.split() |> List.last(),
      type: :object,
      properties: %{data: data_schema},
      required: [:data]
    }

    if description, do: Map.put(envelope, :description, description), else: envelope
  end
end
