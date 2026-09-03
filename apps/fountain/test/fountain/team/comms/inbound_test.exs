defmodule Fountain.Team.Comms.InboundTest do
  # Flips the `team_comms` flag through global app env, so not async.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Audit, Team}
  alias Fountain.Team.Comms.Inbound
  alias Fountain.Team.Contact
  alias Fountain.Conversations.ConversationServer

  @teammate_number "+15551234567"
  @owner "+15550001111"

  setup do
    previous = Application.get_env(:fountain, :feature_flag_overrides)
    Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => true})
    Inbound.Seen.reset()

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :feature_flag_overrides, previous),
        else: Application.delete_env(:fountain, :feature_flag_overrides)
    end)

    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, name: "Ada")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        status: "idle",
        channel_id: Team.channel()
      )

    contact =
      Repo.insert!(%Contact{
        user_id: user.id,
        agent_id: agent.id,
        email_address: "ada@agentmail.to",
        email_inbox_id: "inbox_1",
        phone_number: @teammate_number,
        phone_number_id: "num_1",
        prompt_from_number: @owner
      })

    test_pid = self()

    stub(ConversationServer, :send_prompt, fn id, text, images, opts ->
      send(test_pid, {:sent, id, text, images, opts})
      :ok
    end)

    {:ok, user: user, agent: agent, conv: conv, contact: contact}
  end

  defp payload(overrides \\ %{}) do
    data =
      Map.merge(
        %{
          "conversationId" => "conv_x",
          "numberId" => "num_1",
          "from" => @owner,
          "to" => @teammate_number,
          "message" => "ship it",
          "mediaUrl" => nil,
          "direction" => "inbound",
          "receivedAt" => "2026-08-19T10:00:00Z"
        },
        Map.get(overrides, "data", %{})
      )

    %{"event" => "agent.message", "channel" => "sms", "timestamp" => "x", "data" => data}
    |> Map.merge(Map.delete(overrides, "data"))
  end

  # #1143: the row the ledger prices. AgentPhone charges for a received SMS as
  # well as a sent one, so an inbound message is metered on the same footing.
  test "an inbound text records a durable comms message", %{user: user, contact: contact} do
    assert {:ok, _} = Inbound.handle(payload(), "del_durable")

    assert [message] = Fountain.Repo.all(Fountain.Team.CommsMessage)
    assert message.user_id == user.id
    assert message.contact_id == contact.id
    assert message.channel == "sms"
    assert message.direction == "inbound"

    # No provider message id on the payload, so the webhook's own delivery id
    # is the key — still stable per message, and still what a redelivery
    # would collide on.
    assert message.provider_message_id == "del_durable"
  end

  test "the provider's own message id is preferred over the delivery id", %{user: user} do
    payload = payload(%{"data" => %{"id" => "msg_provider_1"}})

    assert {:ok, _} = Inbound.handle(payload, "del_2")

    assert [message] = Fountain.Repo.all(Fountain.Team.CommsMessage)
    assert message.provider_message_id == "msg_provider_1"
    assert message.user_id == user.id
  end

  test "a text from the allow-listed number becomes a prompt in the teammate's conversation", %{
    conv: conv,
    user: user,
    contact: contact
  } do
    assert {:ok, conv_id} = Inbound.handle(payload(), "del_1")
    assert conv_id == conv.id

    assert_received {:sent, ^conv_id, text, [], opts}
    assert text =~ "[Text message to your number +15551234567 from +15550001111"
    assert text =~ "as a message from the owner"
    assert text =~ "ship it"
    assert text =~ "sms_send tool to +15550001111"
    assert opts[:actor] == "system:agentphone"

    [event] =
      user.id
      |> Audit.list_recent_for_user(10)
      |> Enum.filter(&(&1.action == "team.contact.prompted"))

    assert event.resource_id == contact.id
    assert event.metadata["prompt_bytes"] == 7
    refute inspect(event.metadata) =~ "ship it"

    # AgentPhone charges to receive, so an inbound text is metered on the same
    # footing as a send — otherwise the finance panel prices only half of SMS.
    import Ecto.Query

    [usage] =
      Repo.all(
        from e in Fountain.Billing.UsageEvent,
          where: e.user_id == ^user.id and e.event_type == "comms_sms_received"
      )

    assert usage.resource_id == contact.id
    refute inspect(usage.metadata) =~ "ship it"
  end

  test "the sender is matched after normalization; anyone else is ignored" do
    assert {:ok, _} = Inbound.handle(payload(%{"data" => %{"from" => "(555) 000-1111"}}), "del_a")
    assert_received {:sent, _, _, _, _}

    assert {:ignored, :sender_not_allowed} =
             Inbound.handle(payload(%{"data" => %{"from" => "+15559999999"}}), "del_b")

    refute_received {:sent, _, _, _, _}
  end

  test "a number no teammate owns is ignored" do
    assert {:ignored, :unknown_number} =
             Inbound.handle(payload(%{"data" => %{"to" => "+15557777777"}}), "del_c")
  end

  test "only inbound text channels count" do
    assert {:ignored, :not_inbound} =
             Inbound.handle(payload(%{"data" => %{"direction" => "outbound"}}), "d1")

    assert {:ignored, :not_inbound} = Inbound.handle(payload(%{"channel" => "voice"}), "d2")
    assert {:ignored, :not_a_message} = Inbound.handle(%{"event" => "agent.call_ended"}, "d3")
    assert {:ignored, :empty} = Inbound.handle(payload(%{"data" => %{"message" => "   "}}), "d4")
    refute_received {:sent, _, _, _, _}
  end

  test "a redelivery with the same id is dropped" do
    assert {:ok, _} = Inbound.handle(payload(), "del_same")
    assert {:ignored, :duplicate} = Inbound.handle(payload(), "del_same")
    assert_received {:sent, _, _, _, _}
    refute_received {:sent, _, _, _, _}
  end

  test "with the flag off for the owner nothing is prompted" do
    Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => false})
    assert {:ignored, :unavailable} = Inbound.handle(payload(), "del_off")
  end

  test "an attachment is passed as its URL" do
    assert {:ok, _} =
             Inbound.handle(payload(%{"data" => %{"mediaUrl" => "https://x/y.jpg"}}), "del_m")

    assert_received {:sent, _, text, _, _}
    assert text =~ "(attachment: https://x/y.jpg)"
  end

  describe "STOP / START / HELP from the registered number" do
    setup do
      # Keyword confirmations are texted back best-effort through AgentPhone.
      test = self()

      Req.Test.stub(Fountain.Team.Comms.AgentPhone, fn conn ->
        send(test, {:confirm_sms, conn.body_params})
        Req.Test.json(conn, %{"id" => "sms_c", "status" => "queued"})
      end)

      :ok
    end

    test "STOP opts the number out: no prompt, later texts dropped, audited", %{
      user: user,
      contact: contact
    } do
      assert {:handled, :opted_out} =
               Inbound.handle(payload(%{"data" => %{"message" => " stop "}}), "k1")

      refute_received {:sent, _, _, _, _}

      assert_received {:confirm_sms,
                       %{"number_id" => "num_1", "to_number" => @owner, "body" => body}}

      assert body =~ "opted out"
      assert body =~ "START"

      assert %Contact{prompt_opted_out_at: %DateTime{}} = Fountain.Repo.get!(Contact, contact.id)

      assert {:ignored, :opted_out} = Inbound.handle(payload(), "k2")
      refute_received {:sent, _, _, _, _}

      assert [_] =
               user.id
               |> Audit.list_recent_for_user(10)
               |> Enum.filter(&(&1.action == "team.contact.opted_out"))
    end

    test "START opts back in", %{contact: contact} do
      {:handled, :opted_out} = Inbound.handle(payload(%{"data" => %{"message" => "STOP"}}), "k3")

      assert {:handled, :opted_in} =
               Inbound.handle(payload(%{"data" => %{"message" => "START"}}), "k4")

      assert %Contact{prompt_opted_out_at: nil} = Fountain.Repo.get!(Contact, contact.id)
      assert {:ok, _} = Inbound.handle(payload(), "k5")
      assert_received {:sent, _, _, _, _}
    end

    test "HELP is answered, not forwarded" do
      assert {:handled, :help} =
               Inbound.handle(payload(%{"data" => %{"message" => "help"}}), "k6")

      assert_received {:confirm_sms, %{"body" => body}}
      assert body =~ "STOP to opt out"
      refute_received {:sent, _, _, _, _}
    end

    test "a keyword from a stranger is just ignored" do
      assert {:ignored, :sender_not_allowed} =
               Inbound.handle(
                 payload(%{"data" => %{"from" => "+15559999999", "message" => "STOP"}}),
                 "k7"
               )

      refute_received {:confirm_sms, _}
    end

    test "changing the number is new consent: the opt-out clears", %{
      user: user,
      agent: agent,
      contact: _
    } do
      {:handled, :opted_out} = Inbound.handle(payload(%{"data" => %{"message" => "STOP"}}), "k8")
      Application.put_env(:fountain, :feature_flag_overrides, %{"team_comms" => true})

      assert {:ok, %Contact{prompt_opted_out_at: nil}} =
               Fountain.Team.Comms.update_contact(user.id, agent.id, %{
                 "prompt_from_number" => @owner
               })
    end

    test "a refused confirmation changes nothing" do
      Req.Test.stub(Fountain.Team.Comms.AgentPhone, fn conn ->
        conn
        |> Plug.Conn.put_status(403)
        |> Req.Test.json(%{"detail" => "A2P registration required"})
      end)

      assert {:handled, :opted_out} =
               Inbound.handle(payload(%{"data" => %{"message" => "STOP"}}), "k9")
    end
  end

  test "a send failure is reported, not raised" do
    stub(ConversationServer, :send_prompt, fn _, _, _, _ -> {:error, :busy} end)
    assert {:ignored, {:send_failed, :busy}} = Inbound.handle(payload(), "del_busy")
  end
end
