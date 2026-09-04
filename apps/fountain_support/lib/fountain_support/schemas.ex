defmodule FountainSupport.Schemas do
  @moduledoc """
  The extension's OpenAPI schemas (ADR 0043, #1528).

  Moved out of `FountainWeb.Schemas` unchanged. The **module** names moved;
  every `title:` is byte-identical to what it was in core, because a title is
  the component key in the published document and the four SDKs are generated
  from it (#1411). Renaming one here would be an SDK break.

  `FountainWeb.SchemaWrappers` is imported rather than reimplemented: the
  `%{data: ...}` envelope is the host's shape and stays the host's.
  """

  import FountainWeb.SchemaWrappers, only: [list_response: 2, item_response: 2]

  alias OpenApiSpex.Schema

  defmodule SupportReport do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SupportReport",
      description:
        "A problem report a client filed, with the context it had and where it was forwarded.",
      type: :object,
      properties: %{
        id: %Schema{type: :string, format: :uuid},
        category: %Schema{type: :string, enum: FountainSupport.Report.categories()},
        message: %Schema{type: :string},
        context: %Schema{type: :object, additionalProperties: true},
        client: %Schema{type: :string, nullable: true},
        has_screenshot: %Schema{type: :boolean},
        screenshot_media_type: %Schema{type: :string, nullable: true},
        status: %Schema{type: :string, enum: FountainSupport.Report.statuses()},
        forwarded_at: %Schema{type: :string, format: :"date-time", nullable: true},
        external_url: %Schema{
          type: :string,
          nullable: true,
          description: "The GitHub issue, when one was created."
        },
        forward_error: %Schema{type: :string, nullable: true},
        inserted_at: %Schema{type: :string, format: :"date-time"}
      },
      required: [:id, :category, :message, :status, :inserted_at]
    })
  end

  item_response(SupportReportResponse, of: SupportReport)
  list_response(SupportReportListResponse, of: SupportReport)

  defmodule SupportReportCreateRequest do
    @moduledoc false
    require OpenApiSpex

    OpenApiSpex.schema(%{
      title: "SupportReportCreateRequest",
      type: :object,
      properties: %{
        category: %Schema{type: :string, enum: FountainSupport.Report.categories()},
        message: %Schema{type: :string, minLength: 1, maxLength: 20_000},
        context: %Schema{
          type: :object,
          additionalProperties: true,
          description:
            "What the client knew: conversation_id, agent_id/agent_name/runtime/model, sandbox, " <>
              "presence, recent events, url, app version. 64 KB max. Never secrets.",
          nullable: true
        },
        client: %Schema{
          type: :string,
          maxLength: 200,
          nullable: true,
          example: "fountain-team 2026-08-19 a1db945"
        },
        screenshot: %Schema{
          type: :object,
          nullable: true,
          properties: %{
            data: %Schema{type: :string, description: "base64"},
            media_type: %Schema{
              type: :string,
              enum: ["image/png", "image/jpeg", "image/gif", "image/webp"]
            }
          },
          required: [:data, :media_type]
        }
      },
      required: [:category, :message]
    })
  end
end
