defmodule FountainWeb.Plugs.Cors do
  @moduledoc """
  CORS for `/api/*`, for a browser client on another origin — the standalone
  team app (#810) is the first.

  Off by default: with no configured origins the plug does nothing, and the
  API stays same-origin + non-browser clients only, as it always was. Set
  `API_CORS_ORIGINS` (comma-separated, exact origins such as
  `https://team.example.com`, or `*`) to allow browsers there to call the API
  with a bearer token. No cookies are ever allowed across origins
  (`Access-Control-Allow-Credentials` is never sent), so a session cannot be
  ridden from an allowed origin — only an explicitly presented API key works,
  which is the point.

  A preflight (`OPTIONS` with `Access-Control-Request-Method`) from an allowed
  origin is answered here with 204 and never reaches the router, which would
  otherwise 404 it before any header could be set.
  """
  @behaviour Plug

  import Plug.Conn

  @allowed_methods "GET, POST, PUT, PATCH, DELETE, OPTIONS"
  @allowed_headers "authorization, content-type, last-event-id, accept"
  @exposed_headers "retry-after, x-request-id"

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{path_info: ["api" | _]} = conn, _opts) do
    with [origin] <- get_req_header(conn, "origin"),
         true <- allowed?(origin, origins()) do
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

  defp allowed?(_origin, []), do: false
  defp allowed?(origin, allowed), do: "*" in allowed or origin in allowed

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
