defmodule Fountain.Conversations.OpeningInputTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, Sandbox}

  setup do
    user = insert_active_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    {:ok, user: user, agent: agent, sandbox: sandbox}
  end

  for path <- [:create, :attach] do
    @tag path: path
    test "#{path} refuses invalid text before allocating rows or starting work", ctx do
      reject(Horde.DynamicSupervisor, :start_child, 2)
      reject(ConversationServer, :send_prompt, 4)
      counts = row_counts()

      for prompt <- [" ", "\n\t", 123, ["hello"]] do
        assert {:error, :invalid_prompt} = start(ctx, %{"prompt" => prompt})
        assert row_counts() == counts
      end
    end

    @tag path: path
    test "#{path} refuses images without opening text", ctx do
      reject(Horde.DynamicSupervisor, :start_child, 2)
      reject(ConversationServer, :send_prompt, 4)
      counts = row_counts()
      image = %{media_type: "image/png", data: <<1>>}

      for prompt <- [nil, ""] do
        assert {:error, :invalid_prompt} = start(ctx, %{"prompt" => prompt, "images" => [image]})
        assert row_counts() == counts
      end
    end

    @tag path: path
    test "#{path} rejects malformed, empty, unsupported and oversized image bytes", ctx do
      reject(Horde.DynamicSupervisor, :start_child, 2)
      reject(ConversationServer, :send_prompt, 4)
      counts = row_counts()
      large = :binary.copy(<<0>>, Fountain.Images.max_prompt_image_bytes() + 1)

      for image <- [
            %{},
            %{media_type: "image/png", data: ""},
            %{media_type: "text/html", data: "html"},
            %{media_type: "image/png", data: large}
          ] do
        assert {:error, :invalid_images} =
                 start(ctx, %{"prompt" => "Review", "images" => [image]})

        assert row_counts() == counts
      end
    end

    @tag path: path
    test "#{path} still accepts a launch without an opening prompt", ctx do
      stub(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, self()} end)
      assert {:ok, _} = start(ctx, %{})
    end

    @tag path: path
    test "#{path} passes valid opening text and image bytes to delivery", ctx do
      image = %{media_type: "image/png", data: <<0, 1, 2>>}

      case ctx.path do
        :create ->
          expect(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, self()} end)

        :attach ->
          expect(ConversationServer, :send_prompt, fn _, "Review", [^image], _ -> :ok end)
      end

      assert {:ok, _} = start(ctx, %{"prompt" => "Review", "images" => [image]})

      if ctx.path == :create,
        do: assert_received({:"$gen_cast", {:initial_prompt, "Review", [^image]}})
    end
  end

  @tag path: :create
  test "a context caller may supply string-keyed images", ctx do
    stub(Horde.DynamicSupervisor, :start_child, fn _, _ -> {:ok, self()} end)

    assert {:ok, _} =
             start(ctx, %{
               "prompt" => "Review",
               "images" => [%{"media_type" => "image/png", "data" => <<0, 1, 2>>}]
             })
  end

  @tag path: :create
  test "a string-keyed image is held to the same rules", ctx do
    reject(Horde.DynamicSupervisor, :start_child, 2)

    for image <- [
          %{"media_type" => "text/html", "data" => "html"},
          %{"media_type" => "image/png", "data" => ""},
          %{"media_type" => "image/png"}
        ] do
      assert {:error, :invalid_images} =
               start(ctx, %{"prompt" => "Review", "images" => [image]})
    end
  end

  test "a struct is not an image" do
    assert {:error, :invalid_images} =
             Fountain.Conversations.PromptInput.validate_initial(%{
               "prompt" => "Review",
               "images" => [%URI{}]
             })
  end

  defp start(ctx, extra) do
    attrs = %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id}
    attrs = if ctx.path == :attach, do: Map.put(attrs, "sandbox_id", ctx.sandbox.id), else: attrs
    Conversations.start_conversation(Map.merge(attrs, extra))
  end

  defp row_counts, do: {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
end
