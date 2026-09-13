defmodule Fountain.Conversations.ChannelAllowanceLockOrderTest do
  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.{Conversations, Crypto, InferenceCredentials}
  alias Fountain.Conversations.ExecutionAllowance
  alias Fountain.InferenceCredentials.Source

  for runtime <- ["claude", "codex"] do
    test "#{runtime} channel resume locks the conversation before its allowance" do
      Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        {:ok, dek} = Crypto.load_tenant_key(user.id)
        runtime = unquote(runtime)

        {kind, model} =
          if runtime == "codex",
            do: {:openai_api_key, "openai/gpt-5"},
            else: {:anthropic_api_key, "anthropic/claude-sonnet-5"}

        {:ok, _} = InferenceCredentials.put_credential(user.id, dek, kind, "test-key")
        agent = insert_agent(user_id: user.id, runtime: runtime, model: model)
        {:ok, source, _} = InferenceCredentials.resolve(user.id, model, runtime)
        sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

        Ecto.Changeset.change(sandbox, codex_inference_source: Source.dump(source))
        |> Repo.update!()

        conv =
          insert_conversation(
            user_id: user.id,
            agent: agent,
            sandbox: sandbox,
            status: "idle",
            channel_id: "lock-order",
            inference_source: Source.dump(source)
          )

        ExecutionAllowance.new_changeset(conv.id, %{}) |> Repo.insert!()
        owner = self()

        resume =
          independent(fn ->
            handler = {__MODULE__, self()}

            :telemetry.attach(
              handler,
              [:fountain, :repo, :query],
              &__MODULE__.pause_after_allowance/4,
              {self(), owner, handler}
            )

            try do
              Conversations.start_or_resume_conversation(%{
                "user_id" => user.id,
                "agent_id" => agent.id,
                "channel_id" => "lock-order",
                "labels" => %{"done" => "yes"}
              })
            after
              :telemetry.detach(handler)
            end
          end)

        try do
          assert_receive {:backend, resume_pid, holder}, 5_000
          assert resume_pid == resume.pid
          assert_receive :allowance_read, 5_000

          narrow =
            independent(fn ->
              Conversations.narrow_execution_allowance(conv.id, user.id, %{max_model_turns: 1})
            end)

          try do
            assert_receive {:backend, narrow_pid, waiter}, 5_000
            assert narrow_pid == narrow.pid
            query = await_blocked(waiter, holder, System.monotonic_time(:millisecond) + 5_000)
            # Before the fix this writer already held the conversation's SHARE
            # lock and waited on the allowance. Releasing resume would deadlock
            # its label/source UPDATE against that conversation lock.
            assert query =~ ~s(FROM "conversations")
            send(resume.pid, :continue)
            assert {:ok, resumed, :resumed} = Task.await(resume, 5_000)
            assert resumed.labels == %{"done" => "yes"}
            assert resumed.inference_source == Source.dump(source)
            assert {:ok, allowance} = Task.await(narrow, 5_000)
            assert allowance.limits == %{"max_model_turns" => 1}
          after
            Task.shutdown(narrow, :brutal_kill)
          end
        after
          Task.shutdown(resume, :brutal_kill)
          Repo.delete_all(from c in Conversations.Conversation, where: c.user_id == ^user.id)
          Repo.delete_all(from s in Conversations.Sandbox, where: s.id == ^sandbox.id)
          Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
          Repo.delete!(user)
        end
      end)
    end
  end

  def pause_after_allowance(_, _, %{query: query}, {worker, owner, handler}) do
    if self() == worker and query =~ ~s(FROM "execution_allowances") and query =~ "FOR SHARE" do
      :telemetry.detach(handler)
      send(owner, :allowance_read)

      receive do
        :continue -> :ok
      after
        10_000 -> raise "resume barrier timed out"
      end
    end
  end

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(waiter, holder, deadline) do
    %{rows: [[blocked, query]]} =
      Repo.query!(
        "SELECT $2 = ANY(pg_blocking_pids(pid)), query FROM pg_stat_activity WHERE pid = $1",
        [waiter, holder]
      )

    if blocked do
      query
    else
      assert System.monotonic_time(:millisecond) < deadline, "narrowing did not block on resume"
      Process.sleep(5)
      await_blocked(waiter, holder, deadline)
    end
  end
end
