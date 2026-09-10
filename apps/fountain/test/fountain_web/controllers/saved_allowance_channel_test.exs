defmodule FountainWeb.SavedAllowanceChannelTest do
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.{Conversations, Repo}
  alias Fountain.Conversations.{ConversationServer, ExecutionAllowance}
  alias FountainWeb.{AguiController, OpenAIController}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {_key, raw} = insert_api_key(user)
    flags = Application.get_env(:fountain, :feature_flag_overrides)
    Application.put_env(:fountain, :feature_flag_overrides, %{"openai_compat" => true})

    on_exit(fn ->
      if flags,
        do: Application.put_env(:fountain, :feature_flag_overrides, flags),
        else: Application.delete_env(:fountain, :feature_flag_overrides)
    end)

    owner = self()
    stub(ConversationServer, :pending_caller_calls, fn _ -> [] end)
    stub(ConversationServer, :queue_initial_prompt, fn _, _ -> send(owner, :queued) end)

    stub(Horde.DynamicSupervisor, :start_child, fn _, _ ->
      send(owner, :worker_started)
      {:ok, owner}
    end)

    %{user: user, agent: agent, raw: raw}
  end

  for api <- [:native, :openai, :agui], malformed <- [false, true] do
    test "#{api} refuses malformed=#{malformed} policy before changing caller tools", ctx do
      api = unquote(api)
      channel = channel(api)
      conv = bound(ctx, channel)
      {:ok, conv} = Conversations.set_caller_tools(conv, [tool("original")])
      allowance = save(conv, %{max_model_turns: 2})

      error =
        if unquote(malformed) do
          allowance
          |> Ecto.Changeset.change(limits: %{"private-field" => "do not echo"})
          |> Repo.update!()

          {:error, {:execution_limits_invalid, "unknown_field"}}
        else
          {:error, {:execution_limits_unsupported, ["max_model_turns"]}}
        end

      # Model the downstream prompt guard: it already refuses, but that is
      # too late if channel admission let the controller replace tools first.
      owner = self()

      stub(ConversationServer, :send_prompt, fn _, _, _, _ ->
        send(owner, :prompt_attempted)
        error
      end)

      before = Repo.reload!(conv)
      conn = request(ctx, api, channel)
      assert Repo.reload!(conv) == before
      refute_received :prompt_attempted
      refute_received :queued
      refute_received :worker_started
      assert Conversations._unsafe_list_turns(conv.id) == []
      body = json_response(conn, 422)

      code =
        if unquote(malformed),
          do: "execution_limits_invalid",
          else: "execution_limits_unsupported"

      if unquote(api == :openai) do
        assert body["error"]["code"] == code
        assert body["error"]["type"] == "invalid_request_error"
      else
        assert body["error"] == code
      end

      refute Jason.encode!(body) =~ "private-field"
      refute Jason.encode!(body) =~ "do not echo"
    end
  end

  test "a suspended binding is refused and remains available for read-only lookup", ctx do
    conv = bound(ctx, "parked")
    conv.sandbox |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
    save(conv, %{wall_time_seconds: 30})
    attrs = attrs(ctx, "parked")

    assert {:error, {:execution_limits_unsupported, ["wall_time_seconds"]}} =
             Conversations.start_or_resume_conversation(attrs)

    assert Conversations.channel_conversation(attrs).id == conv.id
    assert Repo.reload!(conv.sandbox).status == "suspended"
    refute_received :worker_started
  end

  test "absent and empty allowances resume the existing binding", ctx do
    for {channel, limits} <- [{"absent", nil}, {"empty", %{}}] do
      conv = bound(ctx, channel)
      if limits, do: save(conv, limits)

      assert {:ok, resumed, :resumed} =
               Conversations.start_or_resume_conversation(attrs(ctx, channel))

      assert resumed.id == conv.id
      refute_received :worker_started
    end
  end

  test "another tenant cannot resume the binding or inspect its policy", ctx do
    conv = bound(ctx, "private")
    save(conv, %{max_model_turns: 2})
    foreign = insert_verified_user()
    foreign_attrs = Map.put(attrs(ctx, "private"), "user_id", foreign.id)
    assert {:error, :not_found} = Conversations.start_or_resume_conversation(foreign_attrs)
    assert Conversations.channel_conversation(foreign_attrs) == nil
    refute_received :worker_started
  end

  test "explicit fresh rotation does not inherit the old conversation allowance", ctx do
    conv = bound(ctx, "rotate")
    save(conv, %{max_model_turns: 2})

    assert {:ok, fresh, :created} =
             Conversations.start_or_resume_conversation(
               Map.put(attrs(ctx, "rotate"), "fresh", true)
             )

    refute fresh.id == conv.id
    assert Repo.reload!(conv).channel_id == nil
    assert Repo.get_by(ExecutionAllowance, conversation_id: fresh.id) == nil
    assert_received :worker_started
  end

  defp bound(ctx, channel),
    do:
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        channel_id: channel,
        status: "idle"
      )

  defp attrs(ctx, channel),
    do: %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id, "channel_id" => channel}

  defp save(conv, limits),
    do: conv.id |> ExecutionAllowance.new_changeset(limits) |> Repo.insert!()

  defp tool(name),
    do: %{
      "name" => name,
      "description" => name,
      "parameters" => %{"type" => "object", "properties" => %{}}
    }

  defp channel(:native), do: "native-thread"
  defp channel(:openai), do: OpenAIController.channel_id("thread")
  defp channel(:agui), do: AguiController.channel_id("thread")

  defp request(ctx, :native, channel),
    do:
      ctx.conn
      |> authed_with_key(ctx.raw)
      |> post_json("/api/conversations", Map.delete(attrs(ctx, channel), "user_id"))

  defp request(ctx, :openai, _channel) do
    ctx.conn
    |> authed_with_key(ctx.raw)
    |> put_req_header("x-fountain-thread", "thread")
    |> post_json("/v1/chat/completions", %{
      "model" => ctx.agent.id,
      "messages" => [%{"role" => "user", "content" => "continue"}],
      "tools" => [%{"type" => "function", "function" => tool("replacement")}]
    })
  end

  defp request(ctx, :agui, _channel) do
    ctx.conn
    |> authed_with_key(ctx.raw)
    |> post_json("/api/agui/#{ctx.agent.id}", %{
      "threadId" => "thread",
      "runId" => "run",
      "messages" => [%{"role" => "user", "content" => "continue"}],
      "tools" => [tool("replacement")]
    })
  end
end
