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

    with {:ok, results} <- Manifest.apply_manifest(user.id, resources) do
      audit_secret_writes(conn, results)
      render(conn, :create, results: results)
    end
  end

  # A manifest apply is a secret write like any other — `fountain apply` was the
  # third API path that moved secrets without leaving a semantic trail (#530).
  # One event per key actually written, matching the per-key events the LiveView
  # forms and the secret controllers emit.
  defp audit_secret_writes(conn, results) do
    for %{id: id, secrets: secrets} = result <- results,
        not is_nil(id),
        %{key: key, action: :upserted} <- secrets do
      {action, resource_type} = audit_names(result.kind)

      Audited.from_conn(conn, action, resource_type,
        resource_id: id,
        metadata: %{"key" => key, "via" => "apply"}
      )
    end

    :ok
  end

  defp audit_names("Environment"), do: {"environment.secret.write", "secret"}
  defp audit_names("Vault"), do: {"vault.secret.write", "vault_secret"}
end
