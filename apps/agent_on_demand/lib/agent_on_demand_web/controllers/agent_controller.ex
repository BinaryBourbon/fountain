defmodule AgentOnDemandWeb.AgentController do
  use AgentOnDemandWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias AgentOnDemand.Agents
  alias AgentOnDemand.Agents.Agent
  alias AgentOnDemandWeb.Schemas

  action_fallback AgentOnDemandWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Agents"])

  operation(:index,
    summary: "List agents",
    responses: [
      ok: {"Agents", "application/json", Schemas.AgentListResponse}
    ]
  )

  def index(conn, params) do
    current_user = conn.assigns.current_user
    render(conn, :index, agents: Agents.list_agents(current_user.id, build_filters(params)))
  end

  operation(:show,
    summary: "Get an agent",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent", "application/json", Schemas.AgentResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Agents.get_agent(id, current_user.id) do
      nil -> {:error, :not_found}
      agent -> render(conn, :show, agent: agent)
    end
  end

  operation(:create,
    summary: "Create an agent",
    request_body: {"Agent attributes", "application/json", Schemas.AgentRequest},
    responses: [
      created: {"Agent", "application/json", Schemas.AgentResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def create(conn, params) do
    current_user = conn.assigns.current_user

    with {:ok, %Agent{} = agent} <- Agents.create_agent(params, current_user.id) do
      conn
      |> put_status(:created)
      |> render(:show, agent: Agents.get_agent!(agent.id, current_user.id))
    end
  end

  operation(:update,
    summary: "Update an agent (partial)",
    description: "Every field is optional; the server merges into the existing record.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Partial agent attributes", "application/json", Schemas.AgentUpdate},
    responses: [
      ok: {"Agent", "application/json", Schemas.AgentResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.ChangesetError}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    current_user = conn.assigns.current_user

    case Agents.get_agent(id, current_user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, agent} <-
               Agents.update_agent(agent, Map.delete(params, "id"), current_user.id) do
          render(conn, :show, agent: Agents.get_agent!(agent.id, current_user.id))
        end
    end
  end

  operation(:delete,
    summary: "Delete an agent",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    current_user = conn.assigns.current_user

    case Agents.get_agent(id, current_user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        {:ok, _} = Agents.delete_agent(agent, current_user.id)
        send_resp(conn, :no_content, "")
    end
  end

  defp build_filters(params) do
    [
      search: params["search"] || "",
      runtimes: params["runtimes"] || [],
      env_ids: params["env_ids"] || [],
      has_skills: params["has_skills"] == "true",
      has_mcp: params["has_mcp"] == "true"
    ]
  end
end
