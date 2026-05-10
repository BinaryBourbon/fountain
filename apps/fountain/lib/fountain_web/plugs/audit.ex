defmodule FountainWeb.Plugs.Audit do
  @moduledoc """
  Records state-changing API requests to the audit log on the way out.

  Captures:
    * `action`: HTTP verb + last path segment after `/api/` (e.g.
      `POST conversations`, `DELETE environments/:id/secrets/:id`).
    * `resource_type`, `resource_id`: derived from the matched route's
      action + params.
    * `actor`: `"api"` for now; could be made request-driven later.
    * `request_ip`: from `conn.remote_ip`.
    * `metadata`: response status code.

  Read methods (GET) are not audited — they're noisy and rarely
  interesting. Failures (4xx/5xx) are still recorded so we can see
  rejected attempts.
  """

  import Plug.Conn

  alias Fountain.Audit

  @write_methods ~w(POST PUT PATCH DELETE)
  @ignore_paths ~w(/api/openapi.json /api/docs)

  def init(opts), do: opts

  def call(conn, _opts) do
    if should_audit?(conn) do
      register_before_send(conn, &record(&1))
    else
      conn
    end
  end

  defp should_audit?(%{method: m, request_path: p}) do
    m in @write_methods and not Enum.any?(@ignore_paths, &String.starts_with?(p, &1))
  end

  defp record(conn) do
    {resource_type, resource_id} = derive_resource(conn)

    Audit.record(%{
      action: "#{conn.method} #{conn.request_path}",
      resource_type: resource_type,
      resource_id: resource_id,
      actor: "api",
      request_ip: format_ip(conn.remote_ip),
      metadata: %{"status" => conn.status},
      user_id: current_user_id(conn)
    })

    conn
  end

  defp current_user_id(conn) do
    case conn.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  defp derive_resource(conn) do
    params = conn.params || %{}

    cond do
      params["secret_id"] || params["environment_id"] ->
        {"secret", params["secret_id"]}

      params["vault_id"] ->
        {"vault_secret", params["id"]}

      params["conversation_id"] ->
        {"conversation", params["conversation_id"]}

      true ->
        # /api/<resource>[/:id]
        case conn.path_info do
          ["api", res] -> {String.trim_trailing(res, "s"), nil}
          ["api", res, id | _] -> {String.trim_trailing(res, "s"), id}
          _ -> {"unknown", nil}
        end
    end
  end

  defp format_ip(nil), do: nil
  defp format_ip(tuple) when is_tuple(tuple), do: tuple |> :inet.ntoa() |> to_string()
  defp format_ip(other), do: to_string(other)
end
