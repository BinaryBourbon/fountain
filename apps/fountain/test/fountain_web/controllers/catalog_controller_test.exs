defmodule FountainWeb.CatalogControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, raw_key: raw_key}
  end

  test "GET /api/catalog lists the form vocabulary", %{conn: conn, raw_key: key} do
    body = conn |> authed_with_key(key) |> get("/api/catalog") |> json_response(200)
    data = body["data"]

    assert data["runtimes"] == Fountain.Agents.Agent.runtimes()
    assert data["models"]["claude"] == Fountain.Runtimes.Model.suggestions("claude")
    assert Enum.all?(data["models"]["opencode"], &String.contains?(&1, "/"))
    assert data["model_providers"] == Fountain.Runtimes.Model.providers()
    assert is_list(data["sandbox_providers"]["enabled"])
    assert data["sandbox_providers"]["default"] in Fountain.Sandbox.known_providers()
    assert data["package_managers"] == ["apt", "npm"]

    assert data["avatar"] == %{
             "bases" => ~w(robot human alien),
             "moods" => ~w(serious casual goofy)
           }

    assert length(data["mcp_servers"]) ==
             length(Fountain.Connections.McpServerCatalog.entries())

    linear = Enum.find(data["mcp_servers"], &(&1["slug"] == "linear"))
    assert linear["name"] == "Linear"
    assert linear["url"] == "https://mcp.linear.app/mcp"
    assert linear["dcr"] == true
    assert {:ok, _} = Date.from_iso8601(linear["verified_on"])
  end

  test "401 without a key", %{conn: conn} do
    assert conn |> get("/api/catalog") |> json_response(401)
  end
end
