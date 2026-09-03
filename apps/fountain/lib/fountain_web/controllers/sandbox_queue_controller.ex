defmodule FountainWeb.SandboxQueueController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.SandboxQueue
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController
  plug OpenApiSpex.Plug.CastAndValidate, replace_params: false

  tags(["Sandbox Queue"])

  operation(:index,
    summary: "List queued sandbox requests",
    description: "Lists the caller's waiting requests in FIFO position order.",
    responses: [
      ok: {"Sandbox requests", "application/json", Schemas.SandboxRequestListResponse}
    ]
  )

  def index(conn, _params) do
    render(conn, :index, requests: SandboxQueue.list_queued(conn.assigns.current_user.id))
  end

  operation(:show,
    summary: "Get a sandbox request",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Sandbox request", "application/json", Schemas.SandboxRequestResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = request <- SandboxQueue.get_request(id, user.id) do
      render(conn, :show, request: request, position: SandboxQueue.position(request))
    else
      _ -> {:error, :not_found}
    end
  end

  operation(:delete,
    summary: "Cancel a queued sandbox request",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Cancelled",
      not_found: {"Not found or no longer queued", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = request <- SandboxQueue.get_request(id, user.id),
         {:ok, _} <- SandboxQueue.cancel_request(request, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    else
      _ -> {:error, :not_found}
    end
  end
end
