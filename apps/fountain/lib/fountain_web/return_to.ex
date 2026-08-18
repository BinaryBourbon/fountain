defmodule FountainWeb.ReturnTo do
  @moduledoc """
  Where to land after login when a request needed a session it did not have
  — the OAuth consent page is the first such request (#818): an app sends the
  browser to `/oauth/authorize?…`, the user is not signed in, signs in, and
  must come back to that exact request rather than the dashboard.

  Only a local path is ever stored or honoured (`/…`, not `//…` and not a
  scheme), so a login cannot be turned into a redirect off-site.
  """
  import Plug.Conn

  @key :return_to

  @doc "Remember the current request (path + query) as the place to return to after login."
  def stash(conn) do
    path =
      if conn.query_string == "",
        do: conn.request_path,
        else: conn.request_path <> "?" <> conn.query_string

    if safe?(path), do: put_session(conn, @key, path), else: conn
  end

  @doc "The stashed path if there is a safe one, else `default`; clears it either way."
  def pop(conn, default) do
    case get_session(conn, @key) do
      path when is_binary(path) ->
        {delete_session(conn, @key), if(safe?(path), do: path, else: default)}

      _ ->
        {conn, default}
    end
  end

  def safe?("/" <> rest) when is_binary(rest),
    do: not String.starts_with?(rest, "/") and not String.starts_with?(rest, "\\")

  def safe?(_), do: false
end
