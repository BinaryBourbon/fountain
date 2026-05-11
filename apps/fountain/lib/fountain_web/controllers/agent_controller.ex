defmodule FountainWeb.AgentController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Agents
  alias Fountain.Agents.Agent
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Agents"])

  operation(:index,
    summary: "List agents",
    responses: [
      ok: {"Agents", "application/json", Schemas.AgentListResponse}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, agents: Agents.list_agents(user.id, []))
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
    user = conn.assigns.current_user

    case Agents.get_agent(id, user.id) do
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
    user = conn.assigns.current_user
    # Force the new agent's user_id to the authenticated user; ignore any
    # client-supplied user_id to prevent owner spoofing.
    attrs = Map.put(params, "user_id", user.id)

    with {:ok, %Agent{} = agent} <- Agents.create_agent(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, agent: Agents.get_agent!(agent.id, user.id))
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
    user = conn.assigns.current_user
    # Strip user_id from update attrs so the owner can't be reassigned.
    attrs = params |> Map.delete("id") |> Map.delete("user_id")

    case Agents.get_agent(id, user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        with {:ok, agent} <- Agents.update_agent(agent, attrs) do
          render(conn, :show, agent: Agents.get_agent!(agent.id, user.id))
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
    user = conn.assigns.current_user

    case Agents.get_agent(id, user.id) do
      nil ->
        {:error, :not_found}

      agent ->
        {:ok, _} = Agents.delete_agent(agent)
        send_resp(conn, :no_content, "")
    end
  end
end
