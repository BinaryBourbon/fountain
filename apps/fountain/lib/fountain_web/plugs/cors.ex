defmodule FountainWeb.Plugs.Cors do
  @moduledoc """
  CORS for `/api/*`, for a browser client on another origin — the standalone
  team app (#810) is the first.

  Two sources, checked in that order.

  **`API_CORS_ORIGINS`** — the operator's list (comma-separated, exact origins
  such as `https://team.example.com`, or `*`). Unset, it admits nothing.

  **A registered OAuth client's redirect origin** (`Fountain.OAuth`, #1125) —
  so that registering an app is enough to call the API from it, and nobody has
  to notice that "Sign in with Fountain" and "fetch from the app" were two
  unrelated pieces of operator config. Costs one indexed lookup per
  cross-origin request that the static list did not already answer — a
  preflight is cached for `access-control-max-age`, the rest are not.

  With neither, the API stays same-origin plus non-browser clients, as it
  always was. No cookies are ever allowed across origins
  (`Access-Control-Allow-Credentials` is never sent), so a session cannot be
  ridden from an allowed origin — only an explicitly presented API key works,
  which is the point, and it is what makes the second source safe: admitting
  an origin admits nobody who does not already hold a key.

  A preflight (`OPTIONS` with `Access-Control-Request-Method`) from an allowed
  origin is answered here with 204 and never reaches the router, which would
  otherwise 404 it before any header could be set.
  """
  @behaviour Plug

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  # `user-agent` is here for the SDK: it stamps one on every request, and
  # Firefox (unlike Chrome) lets a page set it, which turns the call into a
  # preflight asking for a header this list did not name — "CORS Missing
  # Allow Header" on the first request of a signed-in session.
  @allowed_headers "authorization, content-type, last-event-id, accept, user-agent"
  @exposed_headers "retry-after, x-request-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    with [origin] <- get_req_header(conn, "origin"),
         true <- allowed?(origin) do
      conn = put_cors_headers(conn, origin)

      if preflight?(conn) do
        conn |> send_resp(204, "") |> halt()
      else
        conn
      end
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp origins, do: Application.get_env(:fountain, :api_cors_origins, [])

  defp allowed?(origin) do
    allowed = origins()

    "*" in allowed or origin in allowed or Fountain.OAuth.registered_origin?(origin)
  end

  defp preflight?(%Plug.Conn{method: "OPTIONS"} = conn),
    do: get_req_header(conn, "access-control-request-method") != []

  defp preflight?(_conn), do: false

  # The origin is echoed, never `*`: `*` with a bearer-token client is fine
  # today, but echoing keeps the response cacheable per origin (`Vary`) and
  # means a future credentialed mode does not need a rewrite.
  defp put_cors_headers(conn, origin) do
    conn
    |> put_resp_header("access-control-allow-origin", origin)
    |> put_resp_header("access-control-allow-methods", @allowed_methods)
    |> put_resp_header("access-control-allow-headers", @allowed_headers)
    |> put_resp_header("access-control-expose-headers", @exposed_headers)
    |> put_resp_header("access-control-max-age", "600")
    |> put_resp_header("vary", "origin")
  end
end
