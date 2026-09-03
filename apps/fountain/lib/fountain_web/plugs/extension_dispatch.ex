defmodule FountainWeb.Plugs.ExtensionDispatch do
  @moduledoc """
  Serves `/api/<prefix>/...` for an installed extension (ADR 0043, #1505).

  Mounted as the **last** route in the router, forwarded at `/api` inside
  `pipe_through [:accepts_json, :api]`. Two properties fall out of that
  placement, and both are the point:

    * **Core routes win.** Phoenix matches routes in declaration order, so this
      plug only ever sees a request that matched no core route. An extension
      cannot shadow `/api/agents` by declaring `"agents"` — and
      `Fountain.Extensions.validate!/0` refuses that prefix at boot anyway, so
      the collision is a failed deploy rather than a route quietly doing
      nothing.
    * **Authentication is not optional.** The `:api` pipeline — the rate limit,
      `TenantAPIAuth`, the request audit — has already run by the time this
      plug is called, on the host's terms. There is no prefix an extension can
      choose that reaches its plug without `conn.assigns.current_user` being
      set by the host, because there is no second door.

  The extension's plug is called with the prefix moved from `path_info` to
  `script_name`, the way `Phoenix.Router.forward/4` does it, so the extension
  writes its routes relative to its own mount and its path helpers still
  generate `/api/<prefix>/...`.

  ## What is deliberately not caught

  A raise inside an extension's plug propagates, exactly as it would from a
  core controller: 500, and the error reporter sees it. Only the MCP
  contribution is isolated (`Fountain.Extensions.conversation_mcp_servers/2`),
  because there a failure would cost an unrelated conversation its turn. A
  swallowed 500 on an API request would just be a lie to the client.
  """

  @behaviour Plug

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias Fountain.Extensions

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: [prefix | rest]} = conn, _opts) do
    case Extensions.find_by_prefix(prefix) do
      nil -> not_found(conn)
      extension -> dispatch(conn, extension, prefix, rest)
    end
  end

  def call(conn, _opts), do: not_found(conn)

  defp dispatch(conn, extension, prefix, rest) do
    {plug, opts} = normalize(extension.api_plug())

    conn
    |> Map.put(:path_info, rest)
    |> Map.put(:script_name, conn.script_name ++ [prefix])
    |> plug.call(plug.init(opts))
  end

  defp normalize({plug, opts}) when is_atom(plug), do: {plug, opts}
  defp normalize(plug) when is_atom(plug), do: {plug, []}

  # The same body shape the rest of /api answers with, and deliberately the
  # same one for "no such extension", "that extension is not enabled here" and
  # "no such path". A client cannot tell them apart, and should not: whether a
  # given deployment installed an optional integration is not something an
  # unrelated 404 needs to disclose.
  defp not_found(conn) do
    conn
    |> put_status(:not_found)
    |> json(%{error: "Not found", reason: "not_found"})
    |> halt()
  end
end
