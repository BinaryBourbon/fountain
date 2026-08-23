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
      "The caller's requests currently waiting for a free concurrency slot (ADR 0030), " <>
        "oldest first — list order is queue order, and `position` says so explicitly. " <>
        "Terminal requests (started, cancelled, expired, failed) are not listed.",
    responses: [
      ok: {"Sandbox requests", "application/json", Schemas.SandboxRequestListResponse}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, requests: SandboxQueue.list_queued(user.id))
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

    with %{status: "queued"} = request <- SandboxQueue.get_request(id, user.id),
         {:ok, _} <- SandboxQueue.cancel_request(request, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    else
      # A request that already started/expired reads as gone: cancelling it
      # would be rewriting history, and the 404 matches a wrong-owner probe.
      _ -> {:error, :not_found}
    end
  end
end
