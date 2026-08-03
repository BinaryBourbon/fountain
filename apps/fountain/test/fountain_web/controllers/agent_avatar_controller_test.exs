defmodule FountainWeb.AgentAvatarControllerTest do
  use FountainWeb.ConnCase, async: true

  alias Fountain.Agents

  describe "GET /agents/:id/avatar" do
    test "returns 404 when agent has no avatar", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conn = login_user(conn, user)

      conn = get(conn, ~p"/agents/#{agent.id}/avatar")
      assert conn.status == 404
    end

    test "returns the avatar image with the correct content-type", %{conn: conn} do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {:ok, _} = Agents.upload_avatar(agent, "fake-img", "image/png")
      conn = login_user(conn, user)

      conn = get(conn, ~p"/agents/#{agent.id}/avatar")
      assert conn.status == 200
      assert get_resp_header(conn, "content-type") |> hd() =~ "image/png"
      assert conn.resp_body == "fake-img"
    end

    test "pins nosniff and a sandboxing CSP on the bytes", %{conn: conn} do
      # Same treatment as the turn-image endpoint: the bytes are
      # client-originated, so the browser must not be allowed to infer a
      # different type or run the response as active content.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {:ok, _} = Agents.upload_avatar(agent, "fake-img", "image/png")
      conn = login_user(conn, user)

      conn = get(conn, ~p"/agents/#{agent.id}/avatar")
      assert get_resp_header(conn, "x-content-type-options") == ["nosniff"]
      assert get_resp_header(conn, "content-security-policy") == ["default-src 'none'; sandbox"]
    end

    test "a stored media type outside the allowlist is a 404, not served", %{conn: conn} do
      # A row that slipped past ingest validation (or predates it) must not
      # be reflected into Content-Type — that is the self-XSS this endpoint
      # once allowed.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      {:ok, updated} = Agents.upload_avatar(agent, "<script>alert(1)</script>", "image/png")

      updated
      |> Ecto.Changeset.change(%{avatar_media_type: "text/html"})
      |> Fountain.Repo.update!()

      conn = login_user(conn, user)
      conn = get(conn, ~p"/agents/#{agent.id}/avatar")

      assert conn.status == 404
    end

    test "returns 404 for another tenant's agent", %{conn: conn} do
      owner = insert_verified_user()
      other = insert_verified_user()
      agent = insert_agent(user_id: owner.id)
      {:ok, _} = Agents.upload_avatar(agent, "fake-img", "image/jpeg")
      conn = login_user(conn, other)

      conn = get(conn, ~p"/agents/#{agent.id}/avatar")
      assert conn.status == 404
    end

    test "redirects unauthenticated requests to login", %{conn: conn} do
      agent = insert_agent()

      conn = get(conn, ~p"/agents/#{agent.id}/avatar")
      assert redirected_to(conn) =~ "/auth/login"
    end
  end
end
