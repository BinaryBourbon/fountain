defmodule Fountain.SearchTest do
  @moduledoc "`Fountain.Search` (#826) and the `reply_text` materialisation it reads."
  use Fountain.DataCase, async: true

  alias Fountain.{Conversations, Search}

  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  defp acp_tool(name) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "tool_call",
          "toolCallId" => "t1",
          "title" => name,
          "status" => "pending"
        }
      }
    })
  end

  # A turn that ran and ended, with an ACP reply.
  defp finished_turn(conv, prompt, reply, opts \\ []) do
    turn = insert_turn(conv, prompt: prompt, status: "running")

    if reply do
      insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_text(reply)})
    end

    insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_tool("Bash zebra")})

    {:ok, turn} =
      Conversations._unsafe_update_turn(turn, %{
        status: Keyword.get(opts, :status, "completed"),
        ended_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    turn
  end

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(user_id: user.id, agent: agent, title: "Refactor the billing gate")
    {:ok, user: user, agent: agent, conv: conv}
  end

  describe "reply_text materialisation" do
    test "ending a turn writes the assistant text, not tool noise", %{conv: conv} do
      turn = finished_turn(conv, "hello", "The gate lives in Billing.Gate.")
      assert turn.reply_text == "The gate lives in Billing.Gate."

      # A turn with no text ends with reply_text nil, and a non-ending
      # update leaves reply_text alone.
      silent = finished_turn(conv, "quiet", nil, status: "failed")
      assert silent.reply_text == nil

      running = insert_turn(conv, prompt: "still going", status: "running")
      insert_log_event(conv, %{turn_id: running.id, stream: "acp", data: acp_text("partial")})
      {:ok, running} = Conversations._unsafe_update_turn(running, %{acp_prompt_id: 4})
      assert running.reply_text == nil
    end

    test "the backfill fills ended turns that have none, once", %{conv: conv} do
      turn = insert_turn(conv, prompt: "old", status: "completed")
      insert_log_event(conv, %{turn_id: turn.id, stream: "acp", data: acp_text("from before")})
      insert_turn(conv, prompt: "running", status: "running")

      assert 1 == Conversations._unsafe_backfill_reply_texts()
      assert 0 == Conversations._unsafe_backfill_reply_texts()

      assert Repo.reload!(turn).reply_text == "from before"
      assert [%{kind: "reply"}] = Search.search(conv.user_id, "before").hits
    end
  end

  describe "search/3" do
    test "hits across titles, prompts and replies, tenant-scoped, ranked", %{
      user: user,
      agent: agent,
      conv: conv
    } do
      t1 =
        finished_turn(
          conv,
          "where does the billing gate live?",
          "In the Gate plug, under Billing."
        )

      other_conv = insert_conversation(user_id: user.id, agent: agent, title: "Unrelated")
      t2 = finished_turn(other_conv, "rename Gate to Toll", "done, Gate is now Toll")

      # Another tenant's identical text never appears.
      stranger = insert_verified_user()

      s_conv =
        insert_conversation(
          user_id: stranger.id,
          agent: insert_agent(user_id: stranger.id),
          title: "billing gate"
        )

      finished_turn(s_conv, "billing gate", "billing gate")

      %{hits: hits, has_more: false} = Search.search(user.id, "gate")

      assert Enum.map(hits, &{&1.kind, &1.conversation_id, &1.turn_id}) |> Enum.sort() ==
               Enum.sort([
                 {"title", conv.id, nil},
                 {"prompt", conv.id, t1.id},
                 {"reply", conv.id, t1.id},
                 {"prompt", other_conv.id, t2.id},
                 {"reply", other_conv.id, t2.id}
               ])

      title = Enum.find(hits, &(&1.kind == "title"))
      assert title.snippet == "Refactor the billing gate"
      assert title.agent_id == agent.id
      assert %DateTime{} = title.ts

      reply = Enum.find(hits, &(&1.kind == "reply" and &1.turn_id == t1.id))
      assert reply.snippet =~ "Gate plug"
      assert reply.turn_number == t1.turn_number
    end

    test "tool noise is not searchable", %{user: user, conv: conv} do
      finished_turn(conv, "hello", "plain reply")
      assert Search.search(user.id, "zebra").hits == []
    end

    test "filters: agent_id, conversation_id, since, kinds", %{
      user: user,
      agent: agent,
      conv: conv
    } do
      finished_turn(conv, "alpha one", "alpha reply")
      other_agent = insert_agent(user_id: user.id)
      other = insert_conversation(user_id: user.id, agent: other_agent, title: "alpha two")
      finished_turn(other, "alpha three", nil)

      assert Search.search(user.id, "alpha", agent_id: agent.id).hits
             |> Enum.all?(&(&1.conversation_id == conv.id))

      assert Search.search(user.id, "alpha", conversation_id: other.id).hits
             |> Enum.map(& &1.kind)
             |> Enum.sort() == ["prompt", "title"]

      assert Search.search(user.id, "alpha", kinds: ["reply"]).hits |> Enum.map(& &1.kind) ==
               ["reply"]

      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert Search.search(user.id, "alpha", since: future).hits == []
      past = DateTime.add(DateTime.utc_now(), -3600, :second)
      assert length(Search.search(user.id, "alpha", since: past).hits) == 4
    end

    test "paging with limit and offset, has_more", %{user: user, conv: conv} do
      for i <- 1..5, do: finished_turn(conv, "needle #{i}", nil)

      page1 = Search.search(user.id, "needle", limit: 2)
      assert length(page1.hits) == 2
      assert page1.has_more
      page3 = Search.search(user.id, "needle", limit: 2, offset: 4)
      assert length(page3.hits) == 1
      refute page3.has_more

      all = Search.search(user.id, "needle", limit: 100).hits |> Enum.map(& &1.turn_id)

      paged =
        Enum.flat_map(0..2, fn p ->
          Search.search(user.id, "needle", limit: 2, offset: p * 2).hits
        end)
        |> Enum.map(& &1.turn_id)

      assert paged == all
    end

    test "websearch syntax and blank queries", %{user: user, conv: conv} do
      finished_turn(conv, "deploy the api tonight", nil)
      finished_turn(conv, "deploy the docs tomorrow", nil)

      assert Search.search(user.id, "\"deploy the api\"").hits |> length() == 1
      assert Search.search(user.id, "deploy -docs").hits |> length() == 1
      assert Search.search(user.id, "api or docs").hits |> length() == 2
      assert Search.search(user.id, "   ").hits == []
      assert Search.search(user.id, "-only").hits == []
      assert Search.search(user.id, "needle", limit: 0).limit == 1
      assert Search.search(user.id, "needle", limit: 10_000).limit == Search.max_limit()
    end
  end
end
