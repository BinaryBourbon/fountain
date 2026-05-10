defmodule FountainWeb.VaultSecretController do
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Crypto, Vaults}
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Vault Secrets"])

  operation(:index,
    summary: "List secrets in a vault",
    parameters: [vault_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Vault Secrets", "application/json", Schemas.VaultSecretListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def index(conn, %{"vault_id" => vault_id}) do
    user = conn.assigns.current_user

    case Vaults.get_vault(vault_id, user.id) do
      nil -> {:error, :not_found}
      vault -> render(conn, :index, secrets: Vaults.list_secrets(vault))
    end
  end

  operation(:create,
    summary: "Upsert a vault secret",
    description:
      "Sets the value for `key`. If the key exists, the value is overwritten. " <>
        "Values are write-only — subsequent reads never return them.",
    parameters: [vault_id: [in: :path, type: :string, required: true]],
    request_body: {"Vault Secret", "application/json", Schemas.VaultSecretRequest},
    responses: [
      created: {"Vault Secret", "application/json", Schemas.VaultSecretResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, %{"vault_id" => vault_id} = params) do
    user = conn.assigns.current_user

    case Vaults.get_vault(vault_id, user.id) do
      nil ->
        {:error, :not_found}

      vault ->
        attrs = Map.take(params, ["key", "value"])
        {:ok, dek} = Crypto.load_tenant_key(user.id)

        with {:ok, secret} <- Vaults.upsert_secret(vault, attrs, dek) do
          conn
          |> put_status(:created)
          |> render(:show, secret: secret)
        end
    end
  end

  operation(:delete,
    summary: "Delete a vault secret by key",
    parameters: [
      vault_id: [in: :path, type: :string, required: true],
      id: [in: :path, type: :string, required: true, description: "Secret key."]
    ],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"vault_id" => vault_id, "id" => key}) do
    user = conn.assigns.current_user

    with %_{} <- Vaults.get_vault(vault_id, user.id),
         %_{} = secret <- Vaults.get_secret(vault_id, key) do
      {:ok, _} = Vaults.delete_secret(secret)
      send_resp(conn, :no_content, "")
    else
      _ -> {:error, :not_found}
    end
  end
end
