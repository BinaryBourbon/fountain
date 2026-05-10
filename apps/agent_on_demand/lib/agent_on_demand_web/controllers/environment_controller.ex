defmodule AgentOnDemandWeb.EnvironmentController do
  use AgentOnDemandWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias AgentOnDemand.Environments
  alias AgentOnDemand.Environments.Environment
  alias AgentOnDemandWeb.Schemas

  action_fallback AgentOnDemandWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Environments"])

  operation(:index,
    summary: "List environments",
    responses: [
      ok: {"Environments", "application/json", Schemas.EnvironmentListResponse}
    ]
  )

  def index(conn, _params) do
    current_user = conn.assigns.current_user
    render(conn, :index, environments: Environments.list_environments(current_user.id))
  end

  operation(:show,
    summary: "Get an environment",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Environment", "application/json", Schemas.EnvironmentResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Environments.get_environment(id, current_user.id) do
      nil -> {:error, :not_found}
      env -> render(conn, :show, environment: env)
    end
  end

  operation(:create,
    summary: "Create an environment",
    request_body: {"Environment attributes", "application/json", Schemas.EnvironmentRequest},
    responses: [
      created: {"Environment", "application/json", Schemas.EnvironmentResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, params) do
    current_user = conn.assigns.current_user

    with {:ok, %Environment{} = env} <- Environments.create_environment(params, current_user.id) do
      conn
      |> put_status(:created)
      |> render(:show, environment: env)
    end
  end

  operation(:update,
    summary: "Update an environment (partial)",
    description: "Every field is optional; the server merges into the existing record.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Partial environment attributes", "application/json", Schemas.EnvironmentUpdate},
    responses: [
      ok: {"Environment", "application/json", Schemas.EnvironmentResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    current_user = conn.assigns.current_user

    case Environments.get_environment(id, current_user.id) do
      nil ->
        {:error, :not_found}

      env ->
        with {:ok, env} <-
               Environments.update_environment(env, Map.delete(params, "id"), current_user.id) do
          render(conn, :show, environment: env)
        end
    end
  end

  operation(:delete,
    summary: "Delete an environment",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Environments.get_environment(id, current_user.id) do
      nil ->
        {:error, :not_found}

      env ->
        {:ok, _} = Environments.delete_environment(env, current_user.id)
        send_resp(conn, :no_content, "")
    end
  end
end
