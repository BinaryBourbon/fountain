defmodule FountainBuzz.Router do
  @moduledoc """
  The extension's own routes, mounted by the host at `/api/buzz`.

  No pipeline. `FountainWeb.Plugs.ExtensionDispatch` forwards here from inside
  the host's `[:accepts_json, :api]` scope, so content negotiation, the rate
  limit, `TenantAPIAuth` and the request audit have already run and
  `conn.assigns.current_user` is set. An extension gets a mount point, not a
  door of its own — adding a pipeline here would be adding a second, weaker one.

  Paths are written relative to the mount, so `"/agents"` is served at
  `/api/buzz/agents`: the same path it had when this was a core route, which
  ADR 0043 decision 6 promises not to change.
  """
  use Phoenix.Router

  scope "/" do
    resources "/agents", FountainBuzz.AgentController, only: [:index, :create, :update, :delete]
  end
end
