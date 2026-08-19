defmodule FountainWeb.RunnerController do
  @moduledoc """
  Self-hosted runners (ADR 0022).

      GET    /api/runners        — the user's runners, with live online status
      DELETE /api/runners/:id    — forget one (a live daemon is disconnected)
      GET    /api/runners/ws     — the daemon's socket (WebSocket upgrade)

  The socket authenticates like every other `/api` route — a bearer API key,
  full scope — and then hands the connection to `Fountain.Runners.Connection`.
  The daemon identifies itself in the query string (`name`, plus `hostname`,
  `os`, `arch`, `version`, `root` for the row) so registration happens
  before the upgrade and a bad request is an HTTP status, not a close code.
  """

  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Runners
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  tags(["Runners"])

  operation(:index,
    summary: "List self-hosted runners",
    description:
      "Every machine that has ever connected as `fountain runner` for this " <>
        "account, newest connection first, with `online` reflecting whether it " <>
        "holds a connection right now. Sandboxes for an agent whose " <>
        "`sandbox_provider` is `runner` are placed on the most recently " <>
        "connected online runner.",
    responses: [
      ok: {"Runners", "application/json", Schemas.RunnerListResponse},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, runners: Runners.list_runners_with_status(user.id))
  end

  operation(:delete,
    summary: "Forget a runner",
    description:
      "Removes the row and disconnects a live daemon. The machine is not " <>
        "touched — a daemon left running reconnects and re-registers under " <>
        "the same name — and sandbox rows that lived on it are left alone.",
    parameters: [
      id: [in: :path, type: :string, required: true, description: "Runner id."]
    ],
    responses: [
      no_content: "Forgotten",
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      not_found: {"No such runner", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Runners.get_runner(id, user.id) do
      nil ->
        {:error, :not_found}

      runner ->
        {:ok, _} = Runners.delete_runner(runner, Audited.attribution(conn))
        send_resp(conn, :no_content, "")
    end
  end

  operation(:connect,
    summary: "Connect a runner (WebSocket)",
    description:
      "The `fountain runner` daemon's socket. Upgrades to a WebSocket over " <>
        "which Fountain sends sandbox requests and the daemon streams command " <>
        "output; the frame protocol is documented in " <>
        "`Fountain.Runners.Connection` and in the self-hosted runners guide. " <>
        "Not for other clients: it is not a stream of anything.",
    parameters: [
      name: [
        in: :query,
        type: :string,
        required: true,
        description: "The runner's name (lowercase, unique per account)."
      ],
      hostname: [in: :query, type: :string, required: false],
      os: [in: :query, type: :string, required: false],
      arch: [in: :query, type: :string, required: false],
      version: [in: :query, type: :string, required: false, description: "Daemon version."],
      root: [in: :query, type: :string, required: false, description: "Sandbox root on the host."]
    ],
    responses: [
      switching_protocols: "Upgraded",
      bad_request: {"Not a WebSocket upgrade, or a bad name", "application/json", Schemas.Error},
      unauthorized: {"Missing or invalid key", "application/json", Schemas.Error},
      forbidden: {"The presented key lacks full scope", "application/json", Schemas.Error},
      not_found: {"Runners are disabled on this instance", "application/json", Schemas.Error},
      conflict:
        {"A runner with this name is already connected", "application/json", Schemas.Error}
    ]
  )

  def connect(conn, params) do
    user = conn.assigns.current_user

    cond do
      not Fountain.Sandbox.enabled?(:runner) ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "runners_disabled", message: "self-hosted runners are disabled here"})

      not websocket_upgrade?(conn) ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "not_a_websocket", message: "this endpoint expects a WebSocket upgrade"})

      true ->
        register_and_upgrade(conn, user, params)
    end
  end

  defp register_and_upgrade(conn, user, params) do
    attrs = Map.take(params, ~w(name hostname os arch version root))

    case Runners.register(user.id, attrs, Audited.attribution(conn)) do
      {:ok, runner} ->
        if Runners.online?(runner) do
          conn
          |> put_status(:conflict)
          |> json(%{
            error: "runner_already_connected",
            message: "a runner named #{runner.name} is already connected for this account"
          })
        else
          WebSockAdapter.upgrade(
            conn,
            Fountain.Runners.Connection,
            %{runner_id: runner.id, user_id: user.id, name: runner.name},
            timeout: 120_000
          )
        end

      {:error, changeset} ->
        conn
        |> put_status(:bad_request)
        |> put_view(FountainWeb.ChangesetJSON)
        |> render(:error, changeset: changeset)
    end
  end

  defp websocket_upgrade?(conn) do
    conn
    |> get_req_header("upgrade")
    |> Enum.any?(&(String.downcase(&1) == "websocket"))
  end
end
