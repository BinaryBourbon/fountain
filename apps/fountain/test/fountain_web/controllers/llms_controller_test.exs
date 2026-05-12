defmodule FountainWeb.LlmsControllerTest do
  use FountainWeb.ConnCase, async: true

  describe "GET /llms.txt" do
    test "serves the llms.txt index as plain text", %{conn: conn} do
      conn = get(conn, ~p"/llms.txt")

      assert conn.status == 200

      assert ["text/plain; charset=utf-8"] =
               Plug.Conn.get_resp_header(conn, "content-type")

      body = conn.resp_body
      assert body =~ "# Fountain"
      assert body =~ "## API"
      assert body =~ "/api/openapi.json"
      assert body =~ "## For LLMs"
      assert body =~ "/llms-full.txt"
      assert body =~ "/skill"
    end
  end

  describe "GET /llms-full.txt" do
    test "concatenates the index + help corpus + external SKILL.md", %{conn: conn} do
      conn = get(conn, ~p"/llms-full.txt")

      assert conn.status == 200

      assert ["text/plain; charset=utf-8"] =
               Plug.Conn.get_resp_header(conn, "content-type")

      body = conn.resp_body

      # Index is included up top
      assert body =~ "# Fountain"

      # Every curated help topic appears
      for {_slug, title} <- [
            {"quickstart", "Quickstart"},
            {"agents", "Agents"},
            {"environments", "Environments"},
            {"vaults", "Vaults"},
            {"manifest", "Manifest"},
            {"spawning", "Spawning sub-agents"},
            {"api", "API reference"},
            {"secrets-managers", "Secrets managers"},
            {"for-llms", "For LLMs"},
            {"runbook", "Operating"}
          ] do
        assert body =~ title, "expected llms-full.txt to mention #{title}"
      end

      # External SKILL.md tail
      assert body =~ "SKILL.md (external)"
      assert body =~ "FOUNTAIN_API_KEY"
    end
  end

  describe "GET /skill" do
    test "serves the external SKILL.md verbatim", %{conn: conn} do
      conn = get(conn, ~p"/skill")

      assert conn.status == 200

      assert ["text/plain; charset=utf-8"] =
               Plug.Conn.get_resp_header(conn, "content-type")

      body = conn.resp_body
      assert body =~ "---\nname: fountain"
      assert body =~ "FOUNTAIN_API_KEY"
      assert body =~ "fountain apply"
    end

    test "is also reachable at /skills/fountain/SKILL.md", %{conn: conn} do
      conn = get(conn, ~p"/skills/fountain/SKILL.md")

      assert conn.status == 200
      assert conn.resp_body =~ "---\nname: fountain"
    end
  end
end

