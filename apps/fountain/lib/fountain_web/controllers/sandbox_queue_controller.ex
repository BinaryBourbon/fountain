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
    description:
      "The caller's waiting requests, oldest first, each with its one-based position. " <>
        "Only requests that are still waiting appear here. One the drainer has already " <>
        "claimed is not listed, and neither is one that finished; read either by id " <>
        "instead.",
    responses: [
      ok: {"Sandbox requests", "application/json", Schemas.SandboxRequestListResponse},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    render(conn, :index, requests: SandboxQueue.list_queued(conn.assigns.current_user.id))
  end

  operation(:show,
    summary: "Get a sandbox request",
    description:
      "The request's current status. `conversation_id` is set once it started; `error` " <>
        "says why if it failed. A request nobody else owns reads as 404.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Sandbox request", "application/json", Schemas.SandboxRequestResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case SandboxQueue.get_request(id, user.id) do
      nil -> {:error, :not_found}
      request -> render(conn, :show, request: request, position: SandboxQueue.position(request))
    end
  end

  operation(:delete,
    summary: "Cancel a queued sandbox request",
    description:
      "Gives up a request that is still waiting. A request the drainer has already " <>
        "claimed reads as 404 rather than being cancelled out from under a start in " <>
        "flight.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Cancelled",
      not_found: {"Not found or no longer queued", "application/json", Schemas.Error},
      forbidden: {"Forbidden", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %{} = request <- SandboxQueue.get_request(id, user.id) || {:error, :not_found},
         {:ok, _} <- SandboxQueue.cancel_request(request, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    else
      _ -> {:error, :not_found}
    end
  end
end
