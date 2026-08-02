defmodule FountainWeb.ExportController do
  @moduledoc """
  Serves a completed account data export (#288).

  Session-authenticated and owner-scoped: `Exports.get_downloadable_export/2`
  answers `:not_found` identically for a wrong tenant, a missing id, a
  pending/failed export and an expired one, so the response leaks nothing
  about other tenants' artifacts.

  The payload is stored gzipped and served with `content-encoding: gzip`, so
  the bytes on the wire stay small while the browser writes a plain,
  human-readable `.json` file to disk.
  """

  use FountainWeb, :controller

  alias Fountain.Exports
  alias FountainWeb.Audited

  def download(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Exports.get_downloadable_export(id, user.id) do
      {:ok, export} ->
        Audited.from_conn(conn, "account.export_downloaded", "export",
          resource_id: export.id,
          metadata: %{"byte_size" => export.byte_size}
        )

        filename = "fountain-export-#{Date.to_iso8601(Date.utc_today())}.json"

        conn
        |> put_resp_content_type("application/json")
        |> put_resp_header("content-encoding", "gzip")
        |> put_resp_header("content-disposition", ~s(attachment; filename="#{filename}"))
        |> put_resp_header("cache-control", "private, no-store")
        |> send_resp(200, export.payload)

      {:error, :not_found} ->
        send_resp(conn, 404, "")
    end
  end
end
