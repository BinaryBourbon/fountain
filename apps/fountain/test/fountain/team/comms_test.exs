defmodule Fountain.Team.CommsTest do
  # Flips the `team_comms` flag through global app env, so not async. The
  # providers are Req.Test plugs (config/test.exs) stubbed per test.
  use Fountain.DataCase, async: false

  alias Fountain.{Audit, Team}
  alias Fountain.Team.Comms
  alias Fountain.Team.Comms.{AgentMail, AgentPhone}
  alias Fountain.Team.Contact

  setup do
    previous = Application.get_env(:fountain, :feature_flag_overrides)
    on_exit(fn -> restore(:feature_flag_overrides, previous) end)
    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:fountain, key)
  defp restore(key, value), do: Application.put_env(:fountain, key, value)

  defp flag(on?),
    do: Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => on?})

  defp teammate(user, name \\ "Ada") do
    agent = insert_agent(user_id: user.id, name: name)

    insert_conversation(
      user_id: user.id,
      agent: agent,
      status: "idle",
      channel_id: Team.channel()
    )

    agent
  end

  # Happy-path provider stubs: an inbox and a number, echoing what was asked.
  defp stub_providers_ok(test \\ self()) do
    Req.Test.stub(AgentMail, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v0/inboxes"} ->
          send(test, {:agentmail_create, conn.body_params})

          Req.Test.json(conn, %{
            "inbox_id" => "inbox_123",
            "email" => "#{conn.body_params["username"]}@agentmail.to"
          })

        {"DELETE", "/v0/inboxes/inbox_123"} ->
          send(test, :agentmail_delete)
          Req.Test.json(conn, %{})
      end
    end)

    Req.Test.stub(AgentPhone, fn conn ->
      case {conn.method, conn.request_path} do
        {"POST", "/v1/numbers"} ->
          send(test, {:agentphone_create, conn.body_params})
          Req.Test.json(conn, %{"id" => "num_123", "phoneNumber" => "+15551234567"})

        {"DELETE", "/v1/numbers/num_123"} ->
          send(test, :agentphone_delete)
          Req.Test.json(conn, %{})
      end
    end)
  end

  describe "gates" do
    test "status reports the flag and the providers separately" do
      user = insert_verified_user()
      flag(false)
      assert Comms.status(user) == %{enabled: false, configured: true}
      flag(true)
      assert Comms.status(user) == %{enabled: true, configured: true}
    end

    test "provision is refused with the flag off, and nothing is called" do
      user = insert_verified_user()
      agent = teammate(user)
      flag(false)
      Req.Test.stub(AgentMail, fn _ -> flunk("AgentMail must not be called") end)

      assert {:error, :not_enabled} = Comms.provision_contact(user.id, agent.id)
      assert Comms.get_contact(user.id, agent.id) == nil
    end

    test "provision is refused when a provider key is missing" do
      user = insert_verified_user()
      agent = teammate(user)
      flag(true)
      previous = Application.get_env(:fountain, :agentphone_api_key)
      Application.delete_env(:fountain, :agentphone_api_key)
      on_exit(fn -> Application.put_env(:fountain, :agentphone_api_key, previous) end)

      refute Comms.configured?()
      assert {:error, :not_configured} = Comms.provision_contact(user.id, agent.id)
    end
  end

  describe "provision_contact/3" do
    setup do
      flag(true)
      :ok
    end

    test "creates an inbox and a number, records them, audits, broadcasts" do
      user = insert_verified_user()
      agent = teammate(user, "Ada Lovelace")
      stub_providers_ok()
      Team.subscribe(user.id)

      assert {:ok, %Contact{} = contact} = Comms.provision_contact(user.id, agent.id, actor: "ui")

      assert contact.email_inbox_id == "inbox_123"
      assert contact.email_address =~ ~r/^ada-lovelace-[0-9a-f]{6}@agentmail\.to$/
      assert contact.phone_number_id == "num_123"
      assert contact.phone_number == "+15551234567"

      assert_received {:agentmail_create, body}
      assert body["display_name"] == "Ada Lovelace"
      assert body["client_id"] == "fountain-team:" <> agent.id
      assert_received {:agentphone_create, %{"country" => "US"}}
      assert_received {:team_changed, _}

      assert Comms.get_contact(user.id, agent.id).id == contact.id

      [event] =
        user.id
        |> Audit.list_recent_for_user(10)
        |> Enum.filter(&(&1.action == "team.contact.provisioned"))

      assert event.actor == "ui"
      assert event.metadata["channels"] == ["email", "phone"]
      # The trail names the channels, never the address or number.
      refute inspect(event.metadata) =~ "agentmail.to"
      refute inspect(event.metadata) =~ "+1555"
    end

    test "the teammate's contact rides along on the roster" do
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, contact} = Comms.provision_contact(user.id, agent.id)

      assert %{contact: %Contact{id: id}} = Team.get_teammate(user.id, agent.id)
      assert id == contact.id
    end

    test "refuses a second contact for the same teammate" do
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)
      assert {:error, :already_provisioned} = Comms.provision_contact(user.id, agent.id)
    end

    test "an agent not on the team gets not_found" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      assert {:error, :not_found} = Comms.provision_contact(user.id, agent.id)
    end

    test "another tenant's teammate is not_found" do
      user = insert_verified_user()
      other = insert_verified_user()
      agent = teammate(other)
      assert {:error, :not_found} = Comms.provision_contact(user.id, agent.id)
    end

    test "all or nothing: a failed number deletes the inbox again" do
      user = insert_verified_user()
      agent = teammate(user)
      test = self()

      Req.Test.stub(AgentMail, fn conn ->
        case {conn.method, conn.request_path} do
          {"POST", "/v0/inboxes"} ->
            Req.Test.json(conn, %{"inbox_id" => "inbox_123", "email" => "x@agentmail.to"})

          {"DELETE", "/v0/inboxes/inbox_123"} ->
            send(test, :agentmail_delete)
            Req.Test.json(conn, %{})
        end
      end)

      Req.Test.stub(AgentPhone, fn conn ->
        conn |> Plug.Conn.put_status(402) |> Req.Test.json(%{"detail" => "insufficient balance"})
      end)

      assert {:error, {:phone, {:status, 402, %{"detail" => "insufficient balance"}}}} =
               Comms.provision_contact(user.id, agent.id)

      assert_received :agentmail_delete
      assert Comms.get_contact(user.id, agent.id) == nil

      assert [] =
               user.id
               |> Audit.list_recent_for_user(10)
               |> Enum.filter(&(&1.action =~ "team.contact"))
    end

    test "a failed inbox is reported as the email channel, and no number is bought" do
      user = insert_verified_user()
      agent = teammate(user)

      Req.Test.stub(AgentMail, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"message" => "boom"})
      end)

      Req.Test.stub(AgentPhone, fn _ -> flunk("no number without an inbox") end)

      assert {:error, {:email, {:status, 500, _}}} = Comms.provision_contact(user.id, agent.id)
    end
  end

  describe "release_contact/3" do
    setup do
      flag(true)
      :ok
    end

    test "deletes the inbox and the number, removes the row, audits" do
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)

      assert :ok = Comms.release_contact(user.id, agent.id, actor: "api")
      assert_received :agentmail_delete
      assert_received :agentphone_delete
      assert Comms.get_contact(user.id, agent.id) == nil

      assert [event] =
               user.id
               |> Audit.list_recent_for_user(10)
               |> Enum.filter(&(&1.action == "team.contact.released"))

      assert event.actor == "api"
    end

    test "a provider that already forgot the resource counts as released" do
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)

      Req.Test.stub(AgentMail, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end)

      Req.Test.stub(AgentPhone, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{})
      end)

      assert :ok = Comms.release_contact(user.id, agent.id)
      assert Comms.get_contact(user.id, agent.id) == nil
    end

    test "a provider failure keeps the row so nothing is orphaned" do
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)

      Req.Test.stub(AgentPhone, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{})
      end)

      assert {:error, {:phone, {:status, 500, _}}} = Comms.release_contact(user.id, agent.id)
      assert %Contact{} = Comms.get_contact(user.id, agent.id)
    end

    test "no contact is not_found" do
      user = insert_verified_user()
      agent = teammate(user)
      assert {:error, :not_found} = Comms.release_contact(user.id, agent.id)
    end

    test "removing the teammate releases its contact too" do
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)

      assert :ok = Team.remove_teammate(user.id, agent.id)
      assert_received :agentmail_delete
      assert_received :agentphone_delete
      assert Comms.get_contact(user.id, agent.id) == nil
    end
  end

  describe "conversation_mcp_servers/2" do
    test "injects the tools for a teammate with a contact when the flag is on" do
      flag(true)
      user = insert_verified_user()
      agent = teammate(user)
      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)
      %{conversation: conv} = Team.get_teammate(user.id, agent.id)

      assert [%{name: "fountain-comms", type: "http", url: url, headers: headers}] =
               Comms.conversation_mcp_servers(conv.id, "tok_123")

      assert String.ends_with?(url, "/api/mcp/team-comms/" <> conv.id)
      assert headers == [%{name: "Authorization", value: "Bearer tok_123"}]
    end

    test "nothing without a contact, off the team, with the flag off, or without a token" do
      flag(true)
      user = insert_verified_user()
      agent = teammate(user)
      %{conversation: conv} = Team.get_teammate(user.id, agent.id)
      assert [] = Comms.conversation_mcp_servers(conv.id, "tok")

      stub_providers_ok()
      {:ok, _} = Comms.provision_contact(user.id, agent.id)
      assert [_] = Comms.conversation_mcp_servers(conv.id, "tok")
      assert [] = Comms.conversation_mcp_servers(conv.id, "")
      assert [] = Comms.conversation_mcp_servers(conv.id, nil)

      # The same agent, in a conversation that is not the teammate's.
      other = insert_conversation(user_id: user.id, agent: agent)
      assert [] = Comms.conversation_mcp_servers(other.id, "tok")

      flag(false)
      assert [] = Comms.conversation_mcp_servers(conv.id, "tok")

      assert [] = Comms.conversation_mcp_servers("not-a-uuid", "tok")
    end
  end
end
