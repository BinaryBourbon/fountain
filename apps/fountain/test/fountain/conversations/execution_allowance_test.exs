defmodule Fountain.Conversations.ExecutionAllowanceTest do
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.ExecutionAllowance, as: Allowance

  setup do
    %{conversation: insert_conversation()}
  end

  test "persists canonical limits and a revision across reloads", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)
    assert Repo.reload!(allowance) == allowance
    assert allowance.limits == %{"max_model_turns" => 10, "wall_time_seconds" => 60}
    assert {:ok, _} = Ecto.UUID.cast(allowance.revision)
  end

  test "a duplicate insert cannot replace a saved allowance", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)

    assert {:error, changeset} =
             conversation.id |> Allowance.new_changeset(nil) |> Repo.insert()

    assert errors_on(changeset).conversation_id == ["has already been taken"]
    assert Repo.reload!(allowance) == allowance
  end

  test "requires an existing conversation" do
    assert {:error, changeset} =
             Ecto.UUID.generate() |> Allowance.new_changeset(%{}) |> Repo.insert()

    assert errors_on(changeset).conversation_id == ["does not exist"]
  end

  test "malformed limits cannot be saved", %{conversation: conversation} do
    for limits <- [%{max_model_turns: 0}, %{wall_time_seconds: nil}, %{revision: "override"}] do
      assert {:error, changeset} =
               conversation.id |> Allowance.new_changeset(limits) |> Repo.insert()

      assert errors_on(changeset).limits != []
    end

    assert Repo.get(Allowance, conversation.id) == nil
  end

  test "partial narrowing retains omitted fields and advances the revision", %{
    conversation: conversation
  } do
    allowance = insert_allowance(conversation.id)

    updated =
      allowance |> Allowance.narrow_changeset(%{max_model_turns: 3}) |> Repo.update!()

    assert updated.limits == %{"max_model_turns" => 3, "wall_time_seconds" => 60}
    refute updated.revision == allowance.revision

    for request <- [nil, %{}] do
      updated = Repo.reload!(updated) |> Allowance.narrow_changeset(request) |> Repo.update!()
      assert updated.limits == %{"max_model_turns" => 3, "wall_time_seconds" => 60}
    end
  end

  test "widening or clearing a field is refused", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)

    for request <- [%{max_model_turns: 11}, %{wall_time_seconds: nil}] do
      assert {:error, changeset} =
               allowance |> Allowance.narrow_changeset(request) |> Repo.update()

      assert errors_on(changeset).limits != []
      assert Repo.reload!(allowance) == allowance
    end
  end

  test "narrowing cannot replace a saved JSON null with an unrestricted or fresh allowance", %{
    conversation: conversation
  } do
    allowance = insert_allowance(conversation.id)

    Repo.query!(
      "UPDATE execution_allowances SET limits = 'null'::jsonb WHERE conversation_id = $1",
      [Ecto.UUID.dump!(conversation.id)]
    )

    corrupt = Repo.reload!(allowance)
    assert corrupt.limits == nil

    for request <- [nil, %{}, %{max_model_turns: 2}] do
      assert {:error, changeset} = corrupt |> Allowance.narrow_changeset(request) |> Repo.update()
      assert errors_on(changeset).limits == ["execution_limits_invalid: object_required"]
      assert Repo.reload!(corrupt) == corrupt
    end
  end

  test "narrowing preserves malformed saved maps and does not expose their contents", %{
    conversation: conversation
  } do
    corrupt =
      insert_allowance(conversation.id)
      |> Ecto.Changeset.change(limits: %{"private-field" => "private-value"})
      |> Repo.update!()

    for request <- [nil, %{}, %{max_model_turns: 2}] do
      assert {:error, changeset} = corrupt |> Allowance.narrow_changeset(request) |> Repo.update()
      assert errors_on(changeset).limits == ["execution_limits_invalid: unknown_field"]
      assert Repo.reload!(corrupt) == corrupt
    end
  end

  test "an explicitly empty saved allowance can still be narrowed", %{conversation: conversation} do
    allowance = conversation.id |> Allowance.new_changeset(%{}) |> Repo.insert!()
    updated = allowance |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

    assert updated.limits == %{"max_model_turns" => 2}
    refute updated.revision == allowance.revision
  end

  test "stale narrowing cannot overwrite a tighter stored value", %{conversation: conversation} do
    stale = insert_allowance(conversation.id)
    winner = stale |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

    assert_raise Ecto.StaleEntryError, fn ->
      stale |> Allowance.narrow_changeset(%{max_model_turns: 5}) |> Repo.update!()
    end

    assert Repo.reload!(stale) == winner
  end

  test "stale omission cannot restore another field's old allowance", %{
    conversation: conversation
  } do
    stale = insert_allowance(conversation.id)
    winner = stale |> Allowance.narrow_changeset(%{wall_time_seconds: 10}) |> Repo.update!()

    assert {:error, changeset} =
             stale
             |> Allowance.narrow_changeset(%{max_model_turns: 2})
             |> Repo.update(stale_error_field: :revision)

    assert errors_on(changeset).revision == ["is stale"]
    assert Repo.reload!(stale) == winner

    revalidated =
      Repo.reload!(stale) |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

    assert revalidated.limits == %{"max_model_turns" => 2, "wall_time_seconds" => 10}
  end

  test "ordinary conversation updates cannot touch the separate allowance", %{
    conversation: conversation
  } do
    allowance = insert_allowance(conversation.id)

    assert {:ok, _} =
             Fountain.Conversations.update_conversation(conversation, %{title: "renamed"})

    assert Repo.reload!(allowance) == allowance
  end

  test "conversation deletion removes only its own allowance", %{conversation: conversation} do
    allowance = insert_allowance(conversation.id)
    other = insert_conversation() |> Map.fetch!(:id) |> insert_allowance()
    Repo.delete!(conversation)
    assert Repo.get(Allowance, allowance.conversation_id) == nil
    assert Repo.reload!(other) == other
  end

  defp insert_allowance(conversation_id) do
    conversation_id
    |> Allowance.new_changeset(%{max_model_turns: 10, wall_time_seconds: 60})
    |> Repo.insert!()
  end
end

defmodule Fountain.Conversations.ExecutionAllowanceRaceTest do
  use ExUnit.Case, async: false

  alias Fountain.Repo
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.ExecutionAllowance, as: Allowance
  import Fountain.DataCase, only: [errors_on: 1]
  import Fountain.Factory, only: [insert_conversation: 1]

  test "a writer blocked on another connection cannot restore a wider allowance" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      # These rows must be committed: sharing the test's sandbox connection would
      # serialize the queries in Elixir and never exercise PostgreSQL contention.
      {:ok, {user, allowance, sandbox_id}} =
        Repo.transaction(fn ->
          user =
            Repo.insert!(%Fountain.Accounts.User{
              email: "allowance-race-#{Ecto.UUID.generate()}@example.test"
            })

          conversation = insert_conversation(user_id: user.id)
          {user, insert_allowance(conversation.id), conversation.sandbox_id}
        end)

      owner = self()

      winner =
        independent_writer(fn ->
          Repo.transaction(fn ->
            updated =
              allowance |> Allowance.narrow_changeset(%{max_model_turns: 2}) |> Repo.update!()

            send(owner, :narrowed)

            receive do
              :commit -> updated
            after
              5_000 -> raise "commit barrier timed out"
            end
          end)
        end)

      try do
        assert_receive :narrowed, 5_000

        loser =
          independent_writer(fn ->
            allowance
            |> Allowance.narrow_changeset(%{max_model_turns: 5})
            |> Repo.update(stale_error_field: :revision)
          end)

        try do
          assert_receive {:backend, winner_pid, winner_backend}, 5_000
          assert winner_pid == winner.pid
          assert_receive {:backend, loser_pid, loser_backend}, 5_000
          assert loser_pid == loser.pid
          refute winner_backend == loser_backend
          await_blocked(loser_backend, System.monotonic_time(:millisecond) + 5_000)
          send(winner.pid, :commit)
          assert {:ok, updated} = Task.await(winner)
          assert {:error, changeset} = Task.await(loser)
          assert errors_on(changeset).revision == ["is stale"]
          assert Repo.reload!(allowance) == updated
          assert updated.limits["max_model_turns"] == 2
        after
          Task.shutdown(loser, :brutal_kill)
        end
      after
        Task.shutdown(winner, :brutal_kill)
        Repo.delete!(user)
        Repo.get!(Sandbox, sandbox_id) |> Repo.delete!()
        assert Repo.get(Allowance, allowance.conversation_id) == nil
        assert Repo.get(Sandbox, sandbox_id) == nil
      end
    end)
  end

  defp independent_writer(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline, "no PostgreSQL lock wait observed"
      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end

  defp insert_allowance(conversation_id) do
    conversation_id
    |> Allowance.new_changeset(%{max_model_turns: 10, wall_time_seconds: 60})
    |> Repo.insert!()
  end
end
