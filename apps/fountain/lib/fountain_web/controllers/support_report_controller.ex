defmodule FountainWeb.SupportReportController do
  @moduledoc """
  Problem reports over the API (#843): what the "Report a problem" button in a
  client files. The report is stored with the context the client had and
  forwarded to the operator out of band; the caller gets an id to quote.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Support
  alias FountainWeb.{Audited, Schemas}

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Support"])

  operation(:create,
    summary: "File a problem report",
    description:
      "Stores the report with whatever `context` the client attaches (conversation, " <>
        "agent, sandbox, presence, recent events, app version — the facts triage needs; " <>
        "never secrets) and forwards it to the operator: a GitHub issue when the instance " <>
        "configures `SUPPORT_GITHUB_REPO`, and/or mail to `SUPPORT_EMAIL`. Forwarding is " <>
        "asynchronous; `status` is `new` until it lands. Audited as `support.report.created` " <>
        "(category, sizes and context keys — not the message).",
    request_body: {"Report", "application/json", Schemas.SupportReportCreateRequest},
    responses: [
      created: {"Report", "application/json", Schemas.SupportReportResponse},
      unprocessable_entity: {"Validation errors", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, report} <- Support.create_report(user.id, params, Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, report: report)
    end
  end

  operation(:index,
    summary: "List the caller's reports",
    description: "Newest first, with forwarding status and the issue URL when one was created.",
    responses: [ok: {"Reports", "application/json", Schemas.SupportReportListResponse}]
  )

  def index(conn, _params) do
    render(conn, :index, reports: Support.list_reports(conn.assigns.current_user.id))
  end

  operation(:show,
    summary: "Show one report",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Report", "application/json", Schemas.SupportReportResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    case Support.get_report(id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      report -> render(conn, :show, report: report)
    end
  end
end
