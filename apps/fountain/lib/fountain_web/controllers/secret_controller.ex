defmodule FountainWeb.SecretController do
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Crypto, Environments}
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Secrets"])

  operation(:index,
    summary: "List secrets in an environment",
    parameters: [environment_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Secrets", "application/json", Schemas.SecretListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def index(conn, %{"environment_id" => env_id}) do
    case Environments.get_environment(env_id) do
      nil -> {:error, :not_found}
      env -> render(conn, :index, secrets: Environments.list_secrets(env))
    end
  end

  operation(:create,
    summary: "Upsert a secret",
    description:
      "Sets the value for `key`. If the key exists, the value is overwritten. " <>
        "Values are write-only — subsequent reads never return them.",
    parameters: [environment_id: [in: :path, type: :string, required: true]],
    request_body: {"Secret", "application/json", Schemas.SecretRequest},
    responses: [
      created: {"Secret", "application/json", Schemas.SecretResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, %{"environment_id" => env_id} = params) do
    case Environments.get_environment(env_id) do
      nil ->
        {:error, :not_found}

      env ->
        attrs = Map.take(params, ["key", "value"])
        {:ok, dek} = Crypto.load_tenant_key(conn.assigns.current_user.id)

        with {:ok, secret} <- Environments.upsert_secret(env, attrs, dek) do
          conn
          |> put_status(:created)
          |> render(:show, secret: secret)
        end
    end
  end

  operation(:delete,
    summary: "Delete a secret by key",
    parameters: [
      environment_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true, description: "Secret key."]
    ],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"environment_id" => env_id, "id" => key}) do
    case Environments.get_secret(env_id, key) do
      nil ->
        {:error, :not_found}

      secret ->
        {:ok, _} = Environments.delete_secret(secret)
        send_resp(conn, :no_content, "")
    end
  end
end
