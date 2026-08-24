defmodule Fountain.Conversations.SharedSandboxTest do
  # The context-level rules for a sandbox that several conversations hold
  # (ADR 0023 steps 4 and 5): capacity at turn start, co-tenancy, and the
  # machine-wide idle verdict.
  use Fountain.DataCase, async: true

  alias Fountain.Conversations
  alias Fountain.Repo

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "opencode")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, agent: agent, sandbox: sandbox, a: a, b: b}
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp running_turn(conv) do
    insert_turn(conv, %{status: "running", prompt: "go", started_at: now()})
  end

  # A turn that ended `ago` seconds in the past, with its row dated to match.
  defp old_turn(conv, ago) do
    at = DateTime.add(now(), -ago, :second)

    conv
    |> insert_turn(%{status: "completed", prompt: "done", started_at: at, ended_at: at})
    |> Ecto.Changeset.change(inserted_at: at)
    |> Repo.update!()
  end

  describe "_unsafe_running_turns_elsewhere/2" do
    test "counts other conversations' running turns only", %{a: a, b: b, sandbox: sandbox} do
      assert Conversations._unsafe_running_turns_elsewhere(sandbox.id, a.id) == 0

      running_turn(b)
      old_turn(b, 10)
      running_turn(a)

      assert Conversations._unsafe_running_turns_elsewhere(sandbox.id, a.id) == 1
      assert Conversations._unsafe_running_turns_elsewhere(sandbox.id, b.id) == 1
    end
  end

  describe "_unsafe_create_turn_on_sandbox/3" do
    test "refuses at capacity and writes nothing", %{a: a, b: b, sandbox: sandbox} do
      running_turn(b)

      attrs = %{
        conversation_id: a.id,
        turn_number: 1,
        prompt: "hi",
        status: "running",
        started_at: now()
      }

      assert {:error, :sandbox_at_capacity} =
               Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, 1)

      assert Conversations._unsafe_list_turns(a.id) == []
    end

    test "inserts below capacity", %{a: a, sandbox: sandbox} do
      attrs = %{
        conversation_id: a.id,
        turn_number: 1,
        prompt: "hi",
        status: "running",
        started_at: now()
      }

      assert {:ok, turn} = Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, 1)
      assert turn.status == "running"
    end

    test "an unbounded runtime never refuses", %{a: a, b: b, sandbox: sandbox} do
      running_turn(b)

      attrs = %{
        conversation_id: a.id,
        turn_number: 1,
        prompt: "hi",
        status: "running",
        started_at: now()
      }

      assert {:ok, _} =
               Conversations._unsafe_create_turn_on_sandbox(attrs, sandbox.id, :unbounded)
    end
  end

  describe "_unsafe_sandbox_at_capacity?/3" do
    test "is never at capacity for :unbounded", %{a: a, b: b, sandbox: sandbox} do
      running_turn(b)
      refute Conversations._unsafe_sandbox_at_capacity?(sandbox.id, a.id, :unbounded)
      assert Conversations._unsafe_sandbox_at_capacity?(sandbox.id, a.id, 1)
    end
  end

  describe "_unsafe_list_cotenant_ids/2" do
    test "lists the live conversations on the machine other than this one", ctx do
      assert Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, ctx.a.id) == [ctx.b.id]

      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})
      assert Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, ctx.a.id) == []
    end
  end

  describe "_unsafe_sandbox_busy_elsewhere?/4" do
    test "no co-tenant, or the bound switched off, is never busy", ctx do
      {:ok, _} = Conversations.update_conversation(ctx.b, %{status: "terminated"})
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, nil)
    end

    test "a co-tenant mid-turn is busy however old the turn is", ctx do
      turn = running_turn(ctx.b)
      old = DateTime.add(now(), -99_999, :second)
      turn |> Ecto.Changeset.change(inserted_at: old, started_at: old) |> Repo.update!()

      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end

    test "a co-tenant that finished a turn recently is busy; long ago is not", ctx do
      old_turn(ctx.b, 7200)
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)

      old_turn(ctx.b, 60)
      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end

    test "a co-tenant that never took a turn counts by its own row's age", ctx do
      # Fresh row: touched just now.
      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)

      old = DateTime.add(now(), -7200, :second)
      ctx.b |> Ecto.Changeset.change(updated_at: old) |> Repo.update!()
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end

    test "this conversation's own activity does not count", ctx do
      running_turn(ctx.a)
      old = DateTime.add(now(), -7200, :second)
      ctx.b |> Ecto.Changeset.change(updated_at: old) |> Repo.update!()
      refute Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
    end
  end
end
