defmodule FountainWeb.ApplyController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Manifest
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Apply"])

  operation(:create,
    summary: "Apply a compiled manifest (bulk upsert)",
    description:
      "Applies all resources from a compiled fountain.yml manifest in one request. " <>
        "Resources are reconciled by name — environments first, then vaults, then " <>
        "agents — so agent specs may reference an environment by name via " <>
        "`spec.environment`. Application is best-effort per resource: the response " <>
        "is 200 even when individual resources fail, with per-resource errors in " <>
        "the result entries.",
    request_body: {"Compiled manifest", "application/json", Schemas.ApplyRequest},
    responses: [
      ok: {"Per-resource results", "application/json", Schemas.ApplyResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, %{"resources" => resources}) do
    user = conn.assigns.current_user

    with {:ok, results} <- Manifest.apply_manifest(user.id, resources, Audited.attribution(conn)) do
      render(conn, :create, results: results)
    end
  end

end
