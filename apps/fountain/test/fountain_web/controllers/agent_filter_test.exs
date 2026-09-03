defmodule FountainWeb.AgentFilterTest do
  @moduledoc """
  `GET /api/agents` filters.

  `docs/api.md` has documented `?search=` and `?runtime=` since launch, and
  `Agents.list_agents/2` has implemented search, runtimes, environments, skills
  and MCP the whole time — but the controller passed `[]` and ignored every
  param, so the documented behaviour only ever worked in the LiveView.
  """

  use FountainWeb.ConnCase, async: true

  setup do
    # No starter agent (ADR 0038): every count below is of the two agents this
    # setup creates, and a third one nobody asked for would only obscure which
    # filter matched what.
    user = insert_user_without_agents()
    {_key, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)

    claude =
      insert_agent(
        user_id: user.id,
        name: "billing-reconciler",
        runtime: "claude",
        environment_id: env.id,
        skills: [%{"name" => "s", "content" => "# s"}]
      )

    codex = insert_agent(user_id: user.id, name: "docs-writer", runtime: "codex")

    {:ok, raw_key: raw_key, env: env, claude: claude, codex: codex}
  end

  defp names(conn), do: conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["name"])

  defp list(conn, key, query \\ "") do
    conn |> authed_with_key(key) |> get("/api/agents" <> query)
  end

  test "no filters lists everything", %{conn: conn, raw_key: key} do
    assert length(names(list(conn, key))) == 2
  end

  test "search matches on name", %{conn: conn, raw_key: key} do
    assert names(list(conn, key, "?search=billing")) == ["billing-reconciler"]
  end

  test "search is case-insensitive", %{conn: conn, raw_key: key} do
    assert names(list(conn, key, "?search=BILLING")) == ["billing-reconciler"]
  end

  test "runtime filters", %{conn: conn, raw_key: key} do
    assert names(list(conn, key, "?runtime=codex")) == ["docs-writer"]
  end

  test "runtime accepts a comma-separated list", %{conn: conn, raw_key: key} do
    assert length(names(list(conn, key, "?runtime=claude,codex"))) == 2
  end

  test "environment_id filters", %{conn: conn, raw_key: key, env: env} do
    assert names(list(conn, key, "?environment_id=#{env.id}")) == ["billing-reconciler"]
  end

  test "has_skills filters", %{conn: conn, raw_key: key} do
    assert names(list(conn, key, "?has_skills=true")) == ["billing-reconciler"]
  end

  test "an empty filter value is ignored rather than matching nothing", %{
    conn: conn,
    raw_key: key
  } do
    # A client building a query string from optional fields sends these.
    assert length(names(list(conn, key, "?search=&runtime="))) == 2
  end

  test "filters still respect tenancy", %{conn: conn, raw_key: key} do
    other = insert_verified_user()
    insert_agent(user_id: other.id, name: "billing-someone-elses", runtime: "claude")

    assert names(list(conn, key, "?search=billing")) == ["billing-reconciler"]
  end
end
