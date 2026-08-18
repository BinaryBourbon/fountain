defmodule FountainWeb.Plugs.CorsTest do
  use FountainWeb.ConnCase, async: false

  alias FountainWeb.Plugs.Cors

  setup do
    previous = Application.get_env(:fountain, :api_cors_origins)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :api_cors_origins, previous),
        else: Application.delete_env(:fountain, :api_cors_origins)
    end)

    :ok
  end

  defp call(conn), do: Cors.call(conn, Cors.init([]))

  test "does nothing when no origins are configured", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, [])

    conn =
      conn
      |> Map.put(:path_info, ["api", "team"])
      |> put_req_header("origin", "https://team.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == []
    refute conn.halted
  end

  test "echoes an allowed origin and never allows credentials", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://team.example.com"])

    conn =
      conn
      |> Map.put(:path_info, ["api", "team"])
      |> put_req_header("origin", "https://team.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == ["https://team.example.com"]
    assert get_resp_header(conn, "access-control-allow-credentials") == []
    assert get_resp_header(conn, "vary") == ["origin"]
    refute conn.halted
  end

  test "ignores an origin that is not allowed", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://team.example.com"])

    conn =
      conn
      |> Map.put(:path_info, ["api", "team"])
      |> put_req_header("origin", "https://evil.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "`*` allows any origin, still by echo", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["*"])

    conn =
      conn
      |> Map.put(:path_info, ["api", "team"])
      |> put_req_header("origin", "https://anywhere.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == [
             "https://anywhere.example.com"
           ]
  end

  test "answers a preflight from an allowed origin with 204 and halts", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://team.example.com"])

    conn =
      %{conn | method: "OPTIONS"}
      |> Map.put(:path_info, ["api", "team"])
      |> put_req_header("origin", "https://team.example.com")
      |> put_req_header("access-control-request-method", "POST")
      |> call()

    assert conn.halted
    assert conn.status == 204
    assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "authorization"
    assert hd(get_resp_header(conn, "access-control-allow-headers")) =~ "last-event-id"
  end

  test "leaves non-/api paths alone", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["*"])

    conn =
      conn
      |> Map.put(:path_info, ["dashboard"])
      |> put_req_header("origin", "https://team.example.com")
      |> call()

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "end to end: a preflight against the endpoint is answered before auth", %{conn: conn} do
    Application.put_env(:fountain, :api_cors_origins, ["https://team.example.com"])

    conn =
      conn
      |> put_req_header("origin", "https://team.example.com")
      |> put_req_header("access-control-request-method", "GET")
      |> options("/api/team")

    assert conn.status == 204
    assert get_resp_header(conn, "access-control-allow-origin") == ["https://team.example.com"]
  end
end
