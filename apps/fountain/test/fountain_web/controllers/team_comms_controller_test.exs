defmodule FountainWeb.TeamCommsControllerTest do
  # Flips the `team_comms` flag through global app env, so not async. The
  # providers are Req.Test plugs (config/test.exs) stubbed per test.
  use FountainWeb.ConnCase, async: false

  alias Fountain.Team
  alias Fountain.Team.Comms
  alias Fountain.Team.Comms.{AgentMail, AgentPhone}

  setup do
    previous = Application.get_env(:fountain, :feature_flag_overrides)
    on_exit(fn -> restore(:feature_flag_overrides, previous) end)

    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  defp give(conn, key, agent_id, body \\ %{"prompt_from_number" => "5550001111"}) do
    conn
    |> authed_with_key(key)
    |> put_req_header("content-type", "application/json")
    |> post("/api/team/#{agent_id}/contact", body)
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp flag(on?),
    do: Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => on?})

  defp teammate(user, name \\ "Ada") do
    agent = insert_agent(user_id: user.id, name: name)

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        status: "idle",
        channel_id: Team.channel()
      )

    {agent, conv}
  end

  defp stub_providers_ok do
    Req.Test.stub(AgentMail, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v0/inboxes"} ->
          Req.Test.json(conn, %{"inbox_id" => "inbox_123", "email" => "ada-abc123@agentmail.to"})

        {"DELETE", _} ->
          Req.Test.json(conn, %{})
      end
    end)

    Req.Test.stub(AgentPhone, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/numbers"} ->
          Req.Test.json(conn, %{"id" => "num_123", "phoneNumber" => "+15551234567"})

        {"DELETE", _} ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  describe "GET /api/team/comms" do
    test "reports the two gates", %{conn: conn, raw_key: key} do
      flag(false)
      body = conn |> authed_with_key(key) |> get("/api/team/comms") |> json_response(200)
      assert body["data"] == %{"enabled" => false, "configured" => true}

      flag(true)
      body = conn |> authed_with_key(key) |> get("/api/team/comms") |> json_response(200)
      assert body["data"] == %{"enabled" => true, "configured" => true}
    end
  end

  describe "POST /api/team/:agent_id/contact" do
    test "gives the teammate an email and a phone, and the roster shows them", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      flag(true)
      {agent, _} = teammate(user)
      stub_providers_ok()

      body =
        give(conn, key, agent.id)
        |> json_response(201)

      assert body["data"]["agent_id"] == agent.id
      assert body["data"]["contact"]["email"] == "ada-abc123@agentmail.to"
      assert body["data"]["contact"]["phone"] == "+15551234567"
      assert body["data"]["contact"]["prompt_from_number"] == "+15550001111"

      [entry] =
        conn
        |> authed_with_key(key)
        |> get("/api/team")
        |> json_response(200)
        |> Map.fetch!("data")

      assert entry["contact"]["email"] == "ada-abc123@agentmail.to"
    end

    test "is 404 with the flag off — nothing to discover", %{conn: conn, user: user, raw_key: key} do
      flag(false)
      {agent, _} = teammate(user)
      Req.Test.stub(AgentMail, fn _ -> flunk("no provider call with the flag off") end)

      body =
        give(conn, key, agent.id)
        |> json_response(404)

      assert body["error"] == "team_comms_not_enabled"
    end

    test "is 503 when the instance has no provider keys", %{conn: conn, user: user, raw_key: key} do
      flag(true)
      {agent, _} = teammate(user)
      previous = Application.get_env(:fountain, :agentmail_api_key)
      Application.delete_env(:fountain, :agentmail_api_key)
      on_exit(fn -> Application.put_env(:fountain, :agentmail_api_key, previous) end)

      body =
        give(conn, key, agent.id)
        |> json_response(503)

      assert body["error"] == "team_comms_not_configured"
    end

    test "is 422 without a usable prompt_from_number, and buys nothing", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      flag(true)
      {agent, _} = teammate(user)
      Req.Test.stub(AgentMail, fn _ -> flunk("nothing is bought on a bad request") end)

      # No body at all: the spec requires one (422 from the validator).
      give(conn, key, agent.id, %{}) |> json_response(422)

      give(conn, key, agent.id, %{"prompt_from_number" => "nope"})
      |> json_response(422)
    end

    test "is 409 the second time", %{conn: conn, user: user, raw_key: key} do
      flag(true)
      {agent, _} = teammate(user)
      stub_providers_ok()

      give(conn, key, agent.id)
      |> json_response(201)

      body =
        give(conn, key, agent.id)
        |> json_response(409)

      assert body["error"] == "contact_already_provisioned"
    end

    test "is 424 naming the channel when a provider refuses", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      flag(true)
      {agent, _} = teammate(user)

      Req.Test.stub(AgentMail, fn conn ->
        conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"message" => "slow down"})
      end)

      body =
        give(conn, key, agent.id)
        |> json_response(424)

      assert body == %{
               "error" => "provider_error",
               "channel" => "email",
               "message" => "HTTP 429: slow down"
             }
    end

    test "is 404 for an agent not on the team, or another tenant's", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      flag(true)
      loose = insert_agent(user_id: user.id)
      {theirs, _} = teammate(insert_verified_user())

      give(conn, key, loose.id)
      |> json_response(404)

      give(conn, key, theirs.id)
      |> json_response(404)
    end
  end

  describe "DELETE /api/team/:agent_id/contact" do
    test "releases the contact", %{conn: conn, user: user, raw_key: key} do
      flag(true)
      {agent, _} = teammate(user)
      stub_providers_ok()

      give(conn, key, agent.id)
      |> json_response(201)

      assert conn
             |> authed_with_key(key)
             |> delete("/api/team/#{agent.id}/contact")
             |> response(204)

      assert Comms.get_contact(user.id, agent.id) == nil

      # Gone from the teammate too.
      body = conn |> authed_with_key(key) |> get("/api/team/#{agent.id}") |> json_response(200)
      assert body["data"]["contact"] == nil
    end

    test "is 404 without one", %{conn: conn, user: user, raw_key: key} do
      {agent, _} = teammate(user)

      conn
      |> authed_with_key(key)
      |> delete("/api/team/#{agent.id}/contact")
      |> json_response(404)
    end
  end

  describe "POST /api/mcp/team-comms/:conversation_id" do
    setup %{user: user} do
      flag(true)
      {agent, conv} = teammate(user)
      stub_providers_ok()

      {:ok, contact} =
        Comms.provision_contact(user.id, agent.id, %{"prompt_from_number" => "+15550001111"})

      {:ok, agent: agent, conv: conv, contact: contact}
    end

    defp rpc(conn, raw_key, conv_id, body) do
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/mcp/team-comms/#{conv_id}", body)
    end

    test "initialize + tools/list on the teammate's conversation", %{
      conn: conn,
      raw_key: key,
      conv: conv
    } do
      body =
        rpc(conn, key, conv.id, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})
        |> json_response(200)

      assert body["result"]["serverInfo"]["name"] == "fountain-comms"
      assert body["result"]["instructions"] =~ "ada-abc123@agentmail.to"

      body = rpc(conn, key, conv.id, %{"id" => 2, "method" => "tools/list"}) |> json_response(200)
      names = Enum.map(body["result"]["tools"], & &1["name"])
      assert "email_send" in names
      assert "sms_send" in names
    end

    test "tools/call goes to the provider under Fountain's key and is audited", %{
      conn: conn,
      raw_key: key,
      conv: conv,
      user: user
    } do
      test = self()

      Req.Test.stub(AgentPhone, fn conn ->
        assert {"authorization", "Bearer ap_test_key"} in conn.req_headers
        send(test, {:sms, conn.body_params})
        Req.Test.json(conn, %{"id" => "sms_1", "status" => "queued", "channel" => "sms"})
      end)

      body =
        rpc(conn, key, conv.id, %{
          "id" => 3,
          "method" => "tools/call",
          "params" => %{
            "name" => "sms_send",
            "arguments" => %{"to" => "+15550001111", "body" => "hi"}
          }
        })
        |> json_response(200)

      assert body["result"]["isError"] == false

      assert_received {:sms,
                       %{"number_id" => "num_123", "to_number" => "+15550001111", "body" => "hi"}}

      [event] =
        user.id
        |> Fountain.Audit.list_recent_for_user(20)
        |> Enum.filter(&(&1.action == "team.contact.sent"))

      assert event.actor == "sprite"
      assert event.metadata["tool"] == "sms_send"
      refute inspect(event.metadata) =~ "+15550001111"
    end

    test "a notification is 202 with no body", %{conn: conn, raw_key: key, conv: conv} do
      assert rpc(conn, key, conv.id, %{"method" => "notifications/initialized"}) |> response(202) ==
               ""
    end

    test "is 404 on a conversation that is not the teammate's", %{
      conn: conn,
      raw_key: key,
      user: user,
      agent: agent
    } do
      other = insert_conversation(user_id: user.id, agent: agent)

      assert rpc(conn, key, other.id, %{"id" => 1, "method" => "initialize"})
             |> json_response(404)
    end

    test "is 404 when the teammate has no contact", %{conn: conn, raw_key: key, user: user} do
      {_agent, conv} = teammate(user, "Bob")
      assert rpc(conn, key, conv.id, %{"id" => 1, "method" => "initialize"}) |> json_response(404)
    end

    test "is 403 when the flag is off for the owner", %{conn: conn, raw_key: key, conv: conv} do
      flag(false)
      assert rpc(conn, key, conv.id, %{"id" => 1, "method" => "initialize"}) |> json_response(403)
    end

    test "is 404 for another tenant", %{conn: conn, conv: conv} do
      other = insert_verified_user()
      {_key, other_key} = insert_api_key(other)

      assert rpc(conn, other_key, conv.id, %{"id" => 1, "method" => "initialize"})
             |> json_response(404)
    end
  end
end
