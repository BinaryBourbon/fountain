defmodule FountainSupport.ReportController do
  @moduledoc """
  Problem reports over the API (#843): what the "Report a problem" button in a
  client files. The report is stored with the context the client had and
  forwarded to the operator out of band; the caller gets an id to quote.

  Mounted by the host at `/api/support` (ADR 0043, #1528), inside the existing
  `:api` pipeline — so the rate limit, `TenantAPIAuth`, `current_user` and the
  request audit have already run by the time an action here does. There is no
  pipeline in this app: an extension gets a mount point, not a door of its own.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias FountainSupport, as: Support
  alias FountainSupport.Schemas
  alias FountainWeb.Audited

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Support"])

  operation(:create,
    # Pinned, and deliberately still spelling the module this controller used to
    # be. OpenApiSpex derives operationId from module + action, so the #1528
    # rename would have changed all three — and the published spec is what the
    # four SDKs are generated from (#1411), so the id is a wire value even
    # though it looks like a module name. The same reasoning pinned Buzz's four
    # in #1507.
    operation_id: "FountainWeb.SupportReportController.create",
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
      unprocessable_entity: {"Validation errors", "application/json", FountainWeb.Schemas.Error}
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
    # Pinned; see create/2.
    operation_id: "FountainWeb.SupportReportController.index",
    summary: "List the caller's reports",
    description: "Newest first, with forwarding status and the issue URL when one was created.",
    responses: [ok: {"Reports", "application/json", Schemas.SupportReportListResponse}]
  )

  def index(conn, _params) do
    render(conn, :index, reports: Support.list_reports(conn.assigns.current_user.id))
  end

  operation(:show,
    # Pinned; see create/2.
    operation_id: "FountainWeb.SupportReportController.show",
    summary: "Show one report",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Report", "application/json", Schemas.SupportReportResponse},
      not_found: {"Not found", "application/json", FountainWeb.Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    case Support.get_report(id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      report -> render(conn, :show, report: report)
    end
  end
end
