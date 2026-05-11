defmodule FountainWeb.HealthControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /health" do
    test "returns 200 with status ok", %{conn: conn} do
      conn = get(conn, "/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end

    test "is publicly accessible without authentication", %{conn: conn} do
      # No auth header — should still respond 200
      conn = get(conn, "/health")
      assert conn.status == 200
    end

    test "response content-type is application/json", %{conn: conn} do
      conn = get(conn, "/health")

      assert {"content-type", content_type} =
               List.keyfind(conn.resp_headers, "content-type", 0)

      assert content_type =~ "application/json"
    end
  end
end
