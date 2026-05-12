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
