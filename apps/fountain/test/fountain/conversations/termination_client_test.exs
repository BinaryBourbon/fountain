defmodule Fountain.Conversations.TerminationClientTest do
  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias Fountain.Conversations.ConversationServer

  defmodule Probe do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    def init({owner, reply, conv_id}) do
      {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, conv_id, nil)
      {:ok, {owner, reply}}
    end

    def handle_call(message, _from, {owner, reply} = state) do
      send(owner, {:termination_request, self(), message})

      # A function reply lets a test answer by message shape, which is how a
      # pod predating the tuple clause behaves.
      case reply do
        fun when is_function(fun, 1) -> {:reply, fun.(message), state}
        term -> {:reply, term, state}
      end
    end
  end

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{user: user, sandbox: sandbox, conv: conv}
  end

  test "forwards attribution to the actor and keeps the outer lifecycle audit", ctx do
    pid = probe(ctx.conv.id, :ok)
    opts = [actor: "ui", request_ip: "192.0.2.4"]
    assert :ok = ConversationServer.terminate_conversation(ctx.conv.id, opts)
    assert_received {:termination_request, ^pid, {:terminate_conv, ^opts}}
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.request_ip == "192.0.2.4"
  end

  test "an actor refusal is returned without a completed-termination audit", ctx do
    probe(ctx.conv.id, {:error, :sandbox_unavailable})

    assert {:error, :sandbox_unavailable} =
             ConversationServer.terminate_conversation(ctx.conv.id, actor: "ui")

    assert events(ctx) == []
  end

  for live? <- [true, false] do
    test "an enclosing transaction refuses termination with live_actor=#{live?}", ctx do
      if unquote(live?), do: probe(ctx.conv.id, :ok)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 ConversationServer.terminate_conversation(ctx.conv.id, actor: "ui")
               end)

      refute_received {:termination_request, _, _}
      assert Repo.reload!(ctx.conv).status == "idle"
      assert Repo.reload!(ctx.sandbox).status == "ready"
      assert events(ctx) == []
    end
  end

  describe "rolling deploy" do
    # A pod that predates #1980 has no `{:terminate_conv, opts}` clause, so the
    # tuple reaches the `handle_call/3` catch-all and comes back
    # `{:error, :unknown_call}`. Without the retry the sprite keeps running.
    test "retries the bare atom when the actor pod does not know the tuple", ctx do
      pid =
        probe(ctx.conv.id, fn
          {:terminate_conv, _opts} -> {:error, :unknown_call}
          :terminate_conv -> :ok
        end)

      assert :ok = ConversationServer.terminate_conversation(ctx.conv.id, actor: "ui")

      assert_received {:termination_request, ^pid, {:terminate_conv, _}}
      assert_received {:termination_request, ^pid, :terminate_conv}

      # The outer audit gates on `result == :ok`, so it only survives the
      # fallback if the retry actually succeeded.
      assert [event] = events(ctx)
      assert event.actor == "ui"
    end

    test "does not retry when the actor pod understands the tuple", ctx do
      probe(ctx.conv.id, :ok)
      assert :ok = ConversationServer.terminate_conversation(ctx.conv.id, actor: "ui")
      assert_received {:termination_request, _, {:terminate_conv, _}}
      refute_received {:termination_request, _, :terminate_conv}
    end

    test "does not retry on an ordinary refusal", ctx do
      probe(ctx.conv.id, {:error, :sandbox_unavailable})

      assert {:error, :sandbox_unavailable} =
               ConversationServer.terminate_conversation(ctx.conv.id, actor: "ui")

      assert_received {:termination_request, _, {:terminate_conv, _}}
      refute_received {:termination_request, _, :terminate_conv}
      assert events(ctx) == []
    end

    test "forwards only attribution keys to the actor", ctx do
      pid = probe(ctx.conv.id, :ok)

      assert :ok =
               ConversationServer.terminate_conversation(ctx.conv.id,
                 actor: "ui",
                 request_ip: "192.0.2.9",
                 audit: false
               )

      assert_received {:termination_request, ^pid, {:terminate_conv, forwarded}}
      assert Enum.sort(Keyword.keys(forwarded)) == [:actor, :request_ip]
    end
  end

  defp probe(conv_id, reply) do
    pid = start_supervised!({Probe, {self(), reply, conv_id}})
    assert ConversationServer.whereis(conv_id) == pid
    pid
  end

  defp events(ctx), do: Audit.list_for_user(ctx.user.id, action_prefix: "conversation.terminated")
end
