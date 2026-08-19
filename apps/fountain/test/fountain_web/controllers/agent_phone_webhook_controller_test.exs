defmodule FountainWeb.AgentPhoneWebhookControllerTest do
  # Flips the `team_comms` flag and the webhook secret through global app
  # env, so not async.
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Team
  alias Fountain.Team.Comms.Inbound
  alias Fountain.Team.Contact
  alias Fountain.Conversations.ConversationServer

  @secret "whsec_test"

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
    agent = insert_agent(user_id: user.id)

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        status: "idle",
        channel_id: Team.channel()
      )

    Fountain.Repo.insert!(%Contact{
      user_id: user.id,
      agent_id: agent.id,
      phone_number: "+15551234567",
      phone_number_id: "num_1",
      prompt_from_number: "+15550001111"
    })

    test_pid = self()

    stub(ConversationServer, :send_prompt, fn id, text, _images, _opts ->
      send(test_pid, {:sent, id, text})
      :ok
    end)

    {:ok, conv: conv}
  end

  @body Jason.encode!(%{
          "event" => "agent.message",
          "channel" => "sms",
          "data" => %{
            "from" => "+15550001111",
            "to" => "+15551234567",
            "message" => "hello there",
            "direction" => "inbound"
          }
        })

  defp sign(body, ts, secret \\ @secret) do
    "sha256=" <>
      (:crypto.mac(:hmac, :sha256, secret, "#{ts}.#{body}") |> Base.encode16(case: :lower))
  end

  defp deliver(conn, body, headers) do
    conn =
      Enum.reduce(headers, put_req_header(conn, "content-type", "application/json"), fn {k, v},
                                                                                        c ->
        put_req_header(c, k, v)
      end)

    post(conn, "/api/webhooks/agentphone", body)
  end

  test "a signed delivery from the allow-listed number becomes a prompt", %{
    conn: conn,
    conv: conv
  } do
    ts = to_string(System.os_time(:second))

    body =
      conn
      |> deliver(@body, [
        {"x-webhook-signature", sign(@body, ts)},
        {"x-webhook-timestamp", ts},
        {"x-webhook-id", "del_1"}
      ])
      |> json_response(200)

    assert body == %{"status" => "prompted", "conversation_id" => conv.id}
    assert_received {:sent, _, text}
    assert text =~ "hello there"
  end

  test "a bad signature is 401 and nothing is prompted", %{conn: conn} do
    ts = to_string(System.os_time(:second))

    conn
    |> deliver(@body, [
      {"x-webhook-signature", sign(@body, ts, "other")},
      {"x-webhook-timestamp", ts}
    ])
    |> json_response(401)

    conn |> deliver(@body, []) |> json_response(401)
    refute_received {:sent, _, _}
  end

  test "a stale timestamp is 401 even with a valid signature", %{conn: conn} do
    ts = to_string(System.os_time(:second) - 600)

    conn
    |> deliver(@body, [{"x-webhook-signature", sign(@body, ts)}, {"x-webhook-timestamp", ts}])
    |> json_response(401)

    refute_received {:sent, _, _}
  end

  test "an ignored delivery is still 200, saying why", %{conn: conn} do
    body = Jason.encode!(%{"event" => "agent.call_ended", "data" => %{}})
    ts = to_string(System.os_time(:second))

    assert %{"status" => "ignored", "reason" => "not_a_message"} =
             conn
             |> deliver(body, [
               {"x-webhook-signature", sign(body, ts)},
               {"x-webhook-timestamp", ts}
             ])
             |> json_response(200)
  end

  test "a voice event is declined with a spoken line and a hangup", %{conn: conn} do
    body =
      Jason.encode!(%{
        "event" => "agent.message",
        "channel" => "voice",
        "data" => %{
          "from" => "+15550001111",
          "to" => "+15551234567",
          "transcript" => "hello?",
          "direction" => "inbound"
        }
      })

    ts = to_string(System.os_time(:second))

    assert %{"text" => text, "hangup" => true} =
             conn
             |> deliver(body, [
               {"x-webhook-signature", sign(body, ts)},
               {"x-webhook-timestamp", ts}
             ])
             |> json_response(200)

    assert text =~ "text messages"
    refute_received {:sent, _, _}
  end

  test "a redelivery is 200 and not prompted twice", %{conn: conn} do
    ts = to_string(System.os_time(:second))

    headers = [
      {"x-webhook-signature", sign(@body, ts)},
      {"x-webhook-timestamp", ts},
      {"x-webhook-id", "del_dup"}
    ]

    conn |> deliver(@body, headers) |> json_response(200)

    assert %{"status" => "ignored", "reason" => "duplicate"} =
             conn |> deliver(@body, headers) |> json_response(200)

    assert_received {:sent, _, _}
    refute_received {:sent, _, _}
  end

  test "without a configured secret the endpoint is 503 and processes nothing", %{conn: conn} do
    Application.delete_env(:fountain, :agentphone_webhook_secret)
    on_exit(fn -> Application.put_env(:fountain, :agentphone_webhook_secret, @secret) end)
    ts = to_string(System.os_time(:second))

    conn
    |> deliver(@body, [{"x-webhook-signature", sign(@body, ts)}, {"x-webhook-timestamp", ts}])
    |> json_response(503)

    refute_received {:sent, _, _}
  end
end
