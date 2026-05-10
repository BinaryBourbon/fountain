defmodule AgentOnDemandWeb.VaultController do
  use AgentOnDemandWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias AgentOnDemand.Vaults
  alias AgentOnDemand.Vaults.Vault
  alias AgentOnDemandWeb.Schemas

  action_fallback AgentOnDemandWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Vaults"])

  operation(:index,
    summary: "List vaults",
    responses: [
      ok: {"Vaults", "application/json", Schemas.VaultListResponse}
    ]
  )

  def index(conn, _params) do
    current_user = conn.assigns.current_user
    render(conn, :index, vaults: Vaults.list_vaults(current_user.id))
  end

  operation(:show,
    summary: "Get a vault",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Vault", "application/json", Schemas.VaultResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Vaults.get_vault(id, current_user.id) do
      nil -> {:error, :not_found}
      vault -> render(conn, :show, vault: vault)
    end
  end

  operation(:create,
    summary: "Create a vault",
    request_body: {"Vault attributes", "application/json", Schemas.VaultRequest},
    responses: [
      created: {"Vault", "application/json", Schemas.VaultResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, params) do
    current_user = conn.assigns.current_user

    with {:ok, %Vault{} = vault} <- Vaults.create_vault(params, current_user.id) do
      conn
      |> put_status(:created)
      |> render(:show, vault: vault)
    end
  end

  operation(:update,
    summary: "Update a vault (partial)",
    description: "Every field is optional; the server merges into the existing record.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Partial vault attributes", "application/json", Schemas.VaultUpdate},
    responses: [
      ok: {"Vault", "application/json", Schemas.VaultResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    current_user = conn.assigns.current_user

    case Vaults.get_vault(id, current_user.id) do
      nil ->
        {:error, :not_found}

      vault ->
        with {:ok, vault} <-
               Vaults.update_vault(vault, Map.delete(params, "id"), current_user.id) do
          render(conn, :show, vault: vault)
        end
    end
  end

  operation(:delete,
    summary: "Delete a vault",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Vaults.get_vault(id, current_user.id) do
      nil ->
        {:error, :not_found}

      vault ->
        {:ok, _} = Vaults.delete_vault(vault, current_user.id)
        send_resp(conn, :no_content, "")
    end
  end
end
