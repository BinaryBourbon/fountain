defmodule FountainWeb.ConnectionController do
  @moduledoc """
  Connections (#1178): the provider accounts the tenant has signed in to.

      GET    /api/connections            — the account's connections
      GET    /api/connections/providers  — what this deployment can connect, and where to start
      GET    /api/connections/:id        — one
      DELETE /api/connections/:id        — revoke at the provider and delete

  Every route answers 404 `connections_not_enabled` for an account the
  broker is not on for, the way secret bindings do: the feature does not
  exist there. Connecting an account is a browser round trip
  (`/connections/:provider/start`), not an API call.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.{Broker, Connections}
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug :require_connections

  tags(["Connections"])

  operation(:index,
    summary: "List connections",
    description:
      "Every provider account the tenant has connected, active or revoked. " <>
        "Only for accounts the egress broker is on for (ADR 0019); 404 otherwise.",
    responses: [
      ok: {"Connections", "application/json", Schemas.ConnectionListResponse},
      not_found:
        {"Connections are not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, connections: Connections.list_connections(user.id))
  end

  operation(:providers,
    summary: "List connectable providers",
    description:
      "Every provider this account can connect — Google, and the tenant's own " <>
        "(#1186) — with the scopes each asks for, the env var its token is " <>
        "brokered under, and the console URL that starts the flow (a browser " <>
        "signed in as the account owner). The same list as " <>
        "`GET /api/connection-providers`.",
    responses: [
      ok: {"Providers", "application/json", Schemas.ConnectionProviderListResponse},
      not_found:
        {"Connections are not enabled for this account", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def providers(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :providers, providers: Connections.all_providers(user.id))
  end

  operation(:show,
    summary: "Get a connection",
    parameters: [id: [in: :path, type: :string, description: "Connection id"]],
    responses: [
      ok: {"Connection", "application/json", Schemas.Connection},
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Connections.get_connection(id, user.id) do
      nil -> {:error, :not_found}
      connection -> render(conn, :show, connection: connection)
    end
  end

  operation(:delete,
    summary: "Revoke and delete a connection",
    description:
      "Tells the provider to forget the grant, then deletes the row. The next " <>
        "tool call from an agent that names it fails with `connection revoked`.",
    parameters: [id: [in: :path, type: :string, description: "Connection id"]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    with %Connections.Connection{} = connection <-
           Connections.get_connection(id, user.id) || {:error, :not_found},
         {:ok, _} <- Connections.delete(connection, Audited.attribution(conn)) do
      send_resp(conn, :no_content, "")
    end
  end

  defp require_connections(conn, _opts) do
    if Broker.enabled_for?(conn.assigns.current_user.id) do
      conn
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "connections_not_enabled"})
      |> halt()
    end
  end
end
