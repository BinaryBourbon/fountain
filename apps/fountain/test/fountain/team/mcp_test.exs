defmodule Fountain.Team.McpTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Team
  alias Fountain.Team.Mcp

  setup :verify_on_exit!

  setup do
    user = insert_verified_user()

    eng =
      insert_agent(
        user_id: user.id,
        name: "fountain-maintainer",
        description: "Maintains BinaryBourbon/fountain — the engineer for the server"
      )

    steward =
      insert_agent(
        user_id: user.id,
        name: "home-cloud-steward",
        description: "Keeps the k8s estate repo"
      )

    lead =
      insert_agent(user_id: user.id, name: "team-lead", description: "Jake's gateway to the team")

    for a <- [eng, steward, lead] do
      insert_conversation(%{
        user_id: user.id,
        agent: a,
        status: "idle",
        channel_id: Team.channel()
      })
    end

    self_entry = Team.get_teammate(user.id, lead.id)
    ctx = %{user_id: user.id, self: self_entry, actor: "sprite", request_ip: nil}
    %{user: user, eng: eng, steward: steward, lead: lead, ctx: ctx}
  end

  defp call(ctx, name, args \\ %{}) do
    Mcp.handle(
      %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => %{"name" => name, "arguments" => args}
      },
      ctx
    )
  end

  defp payload(resp), do: resp["result"].content |> hd() |> Map.fetch!(:text) |> Jason.decode!()

  test "initialize / tools/list advertise the five tools" do
    resp =
      Mcp.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, %{
        user_id: "x",
        self: nil
      })

    assert Enum.map(resp["result"].tools, & &1.name) ==
             ~w(list_teammates get_teammate send_to_teammate wait_for_teammate read_teammate)

    assert :noreply =
             Mcp.handle(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}, %{})
  end

  test "list_teammates names everyone, marks the caller", %{ctx: ctx} do
    rows = ctx |> call("list_teammates") |> payload()

    assert Enum.map(rows, & &1["name"]) |> Enum.sort() ==
             ~w(fountain-maintainer home-cloud-steward team-lead)

    assert Enum.find(rows, & &1["is_you"])["name"] == "team-lead"
    assert Enum.all?(rows, &(&1["presence"] in ~w(online asleep away offline starting working)))
  end

  test "get_teammate resolves a role word, an exact name, and says when it cannot", %{
    ctx: ctx,
    eng: eng
  } do
    assert payload(call(ctx, "get_teammate", %{"query" => "the engineer"}))["agent_id"] == eng.id

    assert payload(call(ctx, "get_teammate", %{"query" => "home-cloud-steward"}))["name"] ==
             "home-cloud-steward"

    assert payload(call(ctx, "get_teammate", %{"query" => "maintainer"}))["agent_id"] == eng.id
    resp = call(ctx, "get_teammate", %{"query" => "zzz nobody"})
    assert resp["result"].isError
  end

  test "send_to_teammate hands the message to their conversation with a from-line; not to yourself",
       %{ctx: ctx, eng: eng} do
    test_pid = self()

    stub(ConversationServer, :send_prompt, fn id, text, images, opts ->
      send(test_pid, {:sent, id, text, images, opts[:actor]})
      :ok
    end)

    resp =
      call(ctx, "send_to_teammate", %{
        "teammate" => "engineer",
        "message" => "please bump the version"
      })

    refute resp["result"].isError
    assert payload(resp)["agent_id"] == eng.id

    assert_received {:sent, _id, text, [], "sprite"}
    assert text =~ "Team message from your teammate team-lead"
    assert text =~ "treat it as the owner delegating to you"
    assert String.ends_with?(text, "please bump the version")

    resp = call(ctx, "send_to_teammate", %{"teammate" => "team-lead", "message" => "hi me"})
    assert resp["result"].isError
  end

  test "send_to_teammate reports busy instead of failing silently", %{ctx: ctx} do
    stub(ConversationServer, :send_prompt, fn _id, _text, _images, _opts -> {:error, :busy} end)
    resp = call(ctx, "send_to_teammate", %{"teammate" => "steward", "message" => "x"})
    assert resp["result"].isError
    assert hd(resp["result"].content).text =~ "busy"
  end

  test "read_teammate returns recent turns with prompt, reply and status", %{
    ctx: ctx,
    eng: eng,
    user: user
  } do
    conv = Team.get_teammate(user.id, eng.id).conversation

    insert_turn(conv, %{
      turn_number: 1,
      prompt: "hello",
      status: "completed",
      reply_text: "hi there"
    })

    insert_turn(conv, %{turn_number: 2, prompt: "bump it", status: "running"})

    p = payload(call(ctx, "read_teammate", %{"teammate" => "fountain-maintainer", "limit" => 5}))
    assert p["teammate"] == "fountain-maintainer"

    assert [
             %{"turn" => 1, "reply" => "hi there", "status" => "completed"},
             %{"turn" => 2, "status" => "running"}
           ] = p["turns"]
  end

  test "tools/list includes wait_for_teammate" do
    resp =
      Mcp.handle(%{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list"}, %{
        user_id: "x",
        self: nil
      })

    assert "wait_for_teammate" in Enum.map(resp["result"].tools, & &1.name)
  end

  test "wait_for_teammate returns immediately when the latest turn is terminal", %{
    ctx: ctx,
    eng: eng,
    user: user
  } do
    conv = Team.get_teammate(user.id, eng.id).conversation

    insert_turn(conv, %{
      turn_number: 1,
      prompt: "hello",
      status: "completed",
      reply_text: "hi there"
    })

    p =
      payload(call(ctx, "wait_for_teammate", %{"teammate" => "engineer", "timeout_seconds" => 5}))

    assert p["done"] == true
    assert p["turn"]["reply"] == "hi there"
  end

  test "wait_for_teammate waits for the turn after since_turn, and times out honestly", %{
    ctx: ctx,
    eng: eng,
    user: user
  } do
    conv = Team.get_teammate(user.id, eng.id).conversation

    insert_turn(conv, %{
      turn_number: 1,
      prompt: "old",
      status: "completed",
      reply_text: "old reply"
    })

    running = insert_turn(conv, %{turn_number: 2, prompt: "new", status: "running"})
    ticks = :counters.new(1, [])

    sleep = fn _ms ->
      :counters.add(ticks, 1, 1)

      if :counters.get(ticks, 1) == 2 do
        {:ok, _} =
          Fountain.Repo.update(
            Ecto.Changeset.change(running, status: "completed", reply_text: "new reply")
          )
      end

      :ok
    end

    p =
      payload(
        call(Map.put(ctx, :sleep, sleep), "wait_for_teammate", %{
          "teammate" => "engineer",
          "since_turn" => 1,
          "timeout_seconds" => 30
        })
      )

    assert p["done"] == true
    assert p["turn"]["turn"] == 2
    assert p["turn"]["reply"] == "new reply"

    insert_turn(conv, %{turn_number: 3, prompt: "stuck", status: "running"})

    p =
      payload(
        call(Map.put(ctx, :sleep, fn _ -> :ok end), "wait_for_teammate", %{
          "teammate" => "engineer",
          "since_turn" => 2,
          "timeout_seconds" => 1
        })
      )

    assert p["timed_out"] == true
    assert p["latest_turn"]["turn"] == 3
  end

  test "conversation_mcp_servers is only for team conversations", %{user: user, eng: eng} do
    conv = Team.get_teammate(user.id, eng.id).conversation

    assert [%{name: "fountain-team", type: "http", url: url}] =
             Team.conversation_mcp_servers(conv.id, "tok")

    assert url =~ "/api/mcp/team/#{conv.id}"
    other = insert_conversation(%{user_id: user.id, agent: eng, status: "idle"})
    assert Team.conversation_mcp_servers(other.id, "tok") == []
    assert Team.conversation_mcp_servers("not-a-uuid", "tok") == []
  end
end
