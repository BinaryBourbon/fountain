defmodule Fountain.Team.Comms.McpTest do
  use ExUnit.Case, async: true

  alias Fountain.Team.Comms.Mcp
  alias Fountain.Team.Contact

  # Fake providers: record the call in the test process, answer canned JSON.
  defmodule FakeMail do
    def send_message(inbox_id, body) do
      send(self(), {:mail_send, inbox_id, body})
      {:ok, %{"message_id" => "msg_1", "thread_id" => "thr_1"}}
    end

    def reply_to_message(inbox_id, message_id, body) do
      send(self(), {:mail_reply, inbox_id, message_id, body})
      {:ok, %{"message_id" => "msg_2", "thread_id" => "thr_1"}}
    end

    def list_messages(inbox_id, params) do
      send(self(), {:mail_list, inbox_id, params})

      {:ok,
       %{
         "count" => 1,
         "messages" => [
           %{
             "message_id" => "msg_9",
             "thread_id" => "thr_9",
             "from" => "Bob <bob@example.com>",
             "to" => ["ada@agentmail.to"],
             "subject" => "hi",
             "timestamp" => "2026-08-19T10:00:00Z",
             "labels" => ["unread"],
             "preview" => "hello there",
             "attachments" => [%{"attachment_id" => "a", "filename" => "x.pdf", "size" => 3}]
           }
         ]
       }}
    end

    def get_message(inbox_id, message_id) do
      send(self(), {:mail_get, inbox_id, message_id})

      {:ok,
       %{
         "message_id" => message_id,
         "thread_id" => "thr_9",
         "from" => "bob@example.com",
         "to" => ["ada@agentmail.to"],
         "subject" => "hi",
         "timestamp" => "2026-08-19T10:00:00Z",
         "labels" => [],
         "text" => "full body",
         "html" => "<p>full body</p>"
       }}
    end
  end

  defmodule FailingMail do
    def send_message(_, _), do: {:error, {:status, 422, %{"message" => "bad recipient"}}}
  end

  # AgentPhone's envelope nests the message under "error".
  defmodule FailingPhone do
    def send_message(_),
      do:
        {:error,
         {:status, 400,
          %{
            "detail" => "Number is not assigned to an agent yet",
            "error" => %{
              "message" => "Number is not assigned to an agent yet",
              "code" => "HTTP_400"
            }
          }}}
  end

  defmodule FakePhone do
    def send_message(body) do
      send(self(), {:sms_send, body})
      {:ok, %{"id" => "sms_1", "status" => "queued", "channel" => "sms"}}
    end

    def list_messages(number_id, params) do
      send(self(), {:sms_list, number_id, params})

      {:ok,
       %{
         "data" => [
           %{
             "id" => "sms_7",
             "from_" => "+15550001111",
             "to" => "+15551234567",
             "body" => "yo",
             "direction" => "inbound",
             "receivedAt" => "2026-08-19T10:00:00Z"
           }
         ],
         "hasMore" => false
       }}
    end
  end

  @contact %Contact{
    id: "c1",
    email_address: "ada@agentmail.to",
    email_inbox_id: "inbox_1",
    phone_number: "+15551234567",
    phone_number_id: "num_1"
  }

  defp ctx(overrides \\ %{}) do
    Map.merge(%{contact: @contact, mail: FakeMail, phone: FakePhone}, overrides)
  end

  # Responses are built with atom keys and serialised by the controller; the
  # JSON round-trip here is what the sandbox sees.
  defp handle(req, ctx), do: req |> Mcp.handle(ctx) |> json()

  defp json(:noreply), do: :noreply
  defp json(resp), do: resp |> Jason.encode!() |> Jason.decode!()

  defp call(name, args, ctx \\ ctx()) do
    handle(
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      },
      ctx
    )
  end

  defp payload(%{"result" => %{"content" => [%{"text" => text}], "isError" => false}}),
    do: Jason.decode!(text)

  describe "protocol" do
    test "initialize names the server and tells the teammate who it is" do
      resp = handle(%{"id" => 1, "method" => "initialize"}, ctx())
      assert resp["result"]["serverInfo"]["name"] == "fountain-comms"
      assert resp["result"]["protocolVersion"] == "2025-06-18"
      assert resp["result"]["instructions"] =~ "ada@agentmail.to"
      assert resp["result"]["instructions"] =~ "+15551234567"
    end

    test "tools/list advertises email, sms and whoami tools" do
      resp = handle(%{"id" => 1, "method" => "tools/list"}, ctx())
      names = Enum.map(resp["result"]["tools"], & &1["name"])

      assert names ==
               ~w(email_send email_reply email_list email_get sms_send sms_list my_contact_info)

      # The descriptions carry the teammate's own address, so the model knows it.
      assert Enum.find(resp["result"]["tools"], &(&1["name"] == "email_send"))["description"] =~
               "ada@agentmail.to"
    end

    test "an email-only contact gets no sms tools, and vice versa" do
      email_only = %{@contact | phone_number: nil, phone_number_id: nil}
      resp = handle(%{"id" => 1, "method" => "tools/list"}, ctx(%{contact: email_only}))
      names = Enum.map(resp["result"]["tools"], & &1["name"])
      refute "sms_send" in names
      assert "email_send" in names

      assert %{"result" => %{"isError" => true, "content" => [%{"text" => msg}]}} =
               call("sms_send", %{"to" => "+1", "body" => "x"}, ctx(%{contact: email_only}))

      assert msg =~ "no phone number"
    end

    test "notifications get no reply; unknown methods are -32601" do
      assert :noreply = handle(%{"method" => "notifications/initialized"}, ctx())
      assert %{"error" => %{"code" => -32_601}} = handle(%{"id" => 3, "method" => "nope"}, ctx())
      assert %{"result" => %{}} = handle(%{"id" => 4, "method" => "ping"}, ctx())
    end
  end

  describe "email tools" do
    test "email_send posts under the teammate's inbox and audits a count, not the recipients" do
      test = self()
      ctx = ctx(%{audit: fn tool, summary -> send(test, {:audit, tool, summary}) end})

      resp =
        call(
          "email_send",
          %{"to" => ["x@y.com", "z@y.com"], "subject" => "s", "text" => "t", "cc" => "c@y.com"},
          ctx
        )

      assert payload(resp) == %{"message_id" => "msg_1", "thread_id" => "thr_1"}

      assert_received {:mail_send, "inbox_1",
                       %{
                         "to" => ["x@y.com", "z@y.com"],
                         "subject" => "s",
                         "text" => "t",
                         "cc" => ["c@y.com"]
                       }}

      assert_received {:audit, "email_send", %{"recipients" => 2}}
    end

    test "email_send accepts a single comma-separated string for `to`" do
      call("email_send", %{"to" => "a@b.com, c@d.com", "subject" => "s", "text" => "t"})
      assert_received {:mail_send, _, %{"to" => ["a@b.com", "c@d.com"]}}
    end

    test "missing arguments are a tool error the model can read" do
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => msg}]}} =
               call("email_send", %{"subject" => "s", "text" => "t"})

      assert msg =~ "missing required argument: to"
      refute_received {:mail_send, _, _}
    end

    test "a provider refusal is a tool error with the provider's message" do
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => msg}]}} =
               call(
                 "email_send",
                 %{"to" => "a@b.com", "subject" => "s", "text" => "t"},
                 ctx(%{mail: FailingMail})
               )

      assert msg =~ "HTTP 422"
      assert msg =~ "bad recipient"
    end

    test "email_reply threads on the message id" do
      call("email_reply", %{"message_id" => "msg_9", "text" => "thanks", "reply_all" => true})

      assert_received {:mail_reply, "inbox_1", "msg_9",
                       %{"text" => "thanks", "reply_all" => true}}
    end

    test "email_list passes the filters through and shapes the summaries" do
      resp = call("email_list", %{"limit" => 5, "unread_only" => true, "from" => "bob"})
      assert_received {:mail_list, "inbox_1", params}
      assert params[:limit] == 5
      assert params[:labels] == ["unread"]
      assert params[:from] == "bob"

      assert %{"count" => 1, "messages" => [m]} = payload(resp)
      assert m["message_id"] == "msg_9"
      assert m["from"] == "Bob <bob@example.com>"
      assert m["preview"] == "hello there"
      assert m["attachments"] == [%{"filename" => "x.pdf", "size" => 3}]
    end

    test "email_list caps the limit and defaults it" do
      call("email_list", %{"limit" => 1000})
      assert_received {:mail_list, _, params}
      assert params[:limit] == 100

      call("email_list", %{})
      assert_received {:mail_list, _, params}
      assert params[:limit] == 20
    end

    test "email_get returns the body" do
      resp = call("email_get", %{"message_id" => "msg_9"})
      assert_received {:mail_get, "inbox_1", "msg_9"}
      assert %{"text" => "full body", "subject" => "hi"} = payload(resp)
    end
  end

  describe "sms tools" do
    test "a nested provider error envelope is described, not crashed on" do
      assert %{"result" => %{"isError" => true, "content" => [%{"text" => msg}]}} =
               call(
                 "sms_send",
                 %{"to" => "+15550001111", "body" => "hey"},
                 ctx(%{phone: FailingPhone})
               )

      assert msg =~ "HTTP 400: Number is not assigned to an agent yet"
    end

    test "sms_send sends from the teammate's number and audits" do
      test = self()
      ctx = ctx(%{audit: fn tool, summary -> send(test, {:audit, tool, summary}) end})

      resp = call("sms_send", %{"to" => "+15550001111", "body" => "hey"}, ctx)
      assert payload(resp) == %{"message_id" => "sms_1", "status" => "queued", "channel" => "sms"}

      assert_received {:sms_send,
                       %{"number_id" => "num_1", "to_number" => "+15550001111", "body" => "hey"}}

      assert_received {:audit, "sms_send", %{}}
    end

    test "sms_list shapes the messages" do
      resp = call("sms_list", %{"limit" => 3})
      assert_received {:sms_list, "num_1", [limit: 3]}
      assert %{"count" => 1, "has_more" => false, "messages" => [m]} = payload(resp)

      assert m == %{
               "message_id" => "sms_7",
               "from" => "+15550001111",
               "to" => "+15551234567",
               "body" => "yo",
               "direction" => "inbound",
               "received_at" => "2026-08-19T10:00:00Z",
               "status" => nil
             }
    end
  end

  test "my_contact_info answers with both" do
    assert payload(call("my_contact_info", %{})) == %{
             "email" => "ada@agentmail.to",
             "phone" => "+15551234567"
           }
  end

  test "an unknown tool is a tool error" do
    assert %{"result" => %{"isError" => true}} = call("launch_missiles", %{})
  end
end
