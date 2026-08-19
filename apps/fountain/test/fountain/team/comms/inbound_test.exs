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

  test "a text from the allow-listed number becomes a prompt in the teammate's conversation", %{
    conv: conv,
    user: user,
    contact: contact
  } do
    assert {:ok, conv_id} = Inbound.handle(payload(), "del_1")
    assert conv_id == conv.id

    assert_received {:sent, ^conv_id, text, [], opts}
    assert text =~ "[Text message from +15550001111 to your number +15551234567]"
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

  test "a send failure is reported, not raised" do
    stub(ConversationServer, :send_prompt, fn _, _, _, _ -> {:error, :busy} end)
    assert {:ignored, {:send_failed, :busy}} = Inbound.handle(payload(), "del_busy")
  end
end
