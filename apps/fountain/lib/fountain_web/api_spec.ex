defmodule FountainWeb.ApiSpec do
  @moduledoc """
  Builds the OpenAPI 3.1 spec from controller `operation` decls + the
  router. Served at `/api/openapi.json`; Swagger UI at `/api/docs`.
  """

  alias OpenApiSpex.{Components, Info, OpenApi, Paths, SecurityScheme, Server}
  alias FountainWeb.{Endpoint, Router}

  @behaviour OpenApi

  @app_version Mix.Project.config()[:version]

  @impl OpenApi
  def spec do
    %OpenApi{
      servers: [Server.from_endpoint(Endpoint)],
      info: %Info{
        title: "Agent on Demand",
        version: @app_version,
        description: """
        HTTP API for Agent on Demand. The same surface backs the LiveView UI
        and the `aod` CLI; if it's not here, it doesn't exist yet.

        All `/api/*` endpoints require a bearer token (`ADMIN_TOKEN`).
        """
      },
      paths: Paths.from_router(Router),
      components: %Components{
        securitySchemes: %{
          "bearer" => %SecurityScheme{
            type: "http",
            scheme: "bearer",
            description: "ADMIN_TOKEN configured at boot."
          }
        }
      },
      security: [%{"bearer" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
