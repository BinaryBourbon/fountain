defmodule Fountain.Conversations.OpeningInputTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, PromptInput, Sandbox}

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

  # Atom-only matching rejected every string-keyed map, so a rejection on its
  # own cannot tell "refused for the right reason" from "never read". Each case
  # pairs the refusal with the accept, which only holds when string keys are
  # read at all. Asserted against `validate_initial/1` directly because the
  # accept half provisions a sandbox through the context and would otherwise
  # spend the tenant's quota once per case.
  test "a string-keyed image is read, not merely refused" do
    good = %{"media_type" => "image/png", "data" => <<0, 1, 2>>}

    for bad <- [
          %{good | "media_type" => "text/html"},
          %{good | "data" => ""},
          Map.delete(good, "data"),
          Map.delete(good, "media_type"),
          %{good | "data" => :binary.copy(<<0>>, Fountain.Images.max_prompt_image_bytes() + 1)}
        ] do
      assert {:error, :invalid_images} =
               PromptInput.validate_initial(%{"prompt" => "Review", "images" => [bad]})

      assert :ok = PromptInput.validate_initial(%{"prompt" => "Review", "images" => [good]})
    end
  end

  test "a struct is refused rather than raised out of Access" do
    assert {:error, :invalid_images} =
             PromptInput.validate_initial(%{"prompt" => "Review", "images" => [%URI{}]})

    # The same shape on a plain map is accepted, so the clause above is the
    # struct head doing its job rather than the map read failing.
    assert :ok =
             PromptInput.validate_initial(%{
               "prompt" => "Review",
               "images" => [%{"media_type" => "image/png", "data" => <<0>>}]
             })
  end

  # Attach rather than create: this is about the bytes surviving the context
  # unchanged, and it needs no second sandbox to say so.
  @tag path: :attach
  test "string-keyed and atom-keyed images reach delivery unchanged", ctx do
    for image <- [
          %{"media_type" => "image/png", "data" => <<0, 1, 2>>},
          %{media_type: "image/png", data: <<0, 1, 2>>}
        ] do
      expect(ConversationServer, :send_prompt, fn _, "Review", [^image], _ -> :ok end)
      assert {:ok, _} = start(ctx, %{"prompt" => "Review", "images" => [image]})
    end
  end

  defp start(ctx, extra) do
    attrs = %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id}
    attrs = if ctx.path == :attach, do: Map.put(attrs, "sandbox_id", ctx.sandbox.id), else: attrs
    Conversations.start_conversation(Map.merge(attrs, extra))
  end

  defp row_counts, do: {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
end
