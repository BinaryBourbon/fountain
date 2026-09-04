defmodule FountainSupport.Router do
  @moduledoc """
  The extension's own routes, mounted by the host at `/api/support`.

  No pipeline. `FountainWeb.Plugs.ExtensionDispatch` forwards here from inside
  the host's `[:accepts_json, :api]` scope, so content negotiation, the rate
  limit, `TenantAPIAuth` and the request audit have already run and
  `conn.assigns.current_user` is set. An extension gets a mount point, not a
  door of its own — adding a pipeline here would be adding a second, weaker one.

  Paths are written relative to the mount, so `"/reports"` is served at
  `/api/support/reports`: the same path it had as a core route, which #1528
  promises not to change.
  """
  use Phoenix.Router

  scope "/" do
    post "/reports", FountainSupport.ReportController, :create
    get "/reports", FountainSupport.ReportController, :index
    get "/reports/:id", FountainSupport.ReportController, :show
  end
end
