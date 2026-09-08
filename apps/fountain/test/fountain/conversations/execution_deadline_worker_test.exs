defmodule Fountain.Conversations.ExecutionDeadlineWorkerTest do
  use Fountain.DataCase, async: false
  use Mimic

  setup :set_mimic_global

  alias Fountain.Conversations.{ExecutionDeadlineWorker, ExecutionGuard, Turn, TurnExecution}

  setup do
    %{user: insert_verified_user()}
  end

  defp execution(user, known? \\ false) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "running")
    past = DateTime.add(DateTime.utc_now(), -120, :second)
    turn = insert_turn(conv, status: "running", started_at: DateTime.truncate(past, :second))
    connection = Ecto.UUID.generate()

    {:ok, row} =
      ExecutionGuard._unsafe_register(turn.id, connection, DateTime.add(past, 60), now: past)

    if known? do
      {:ok, _} = ExecutionGuard._unsafe_claim_spawn(row.id, now: past)
      {:ok, _} = ExecutionGuard._unsafe_bind_identity(row.id, connection, "19")
    end

    %{row: row, turn: turn, conv: conv}
  end

  defp worker(id, terminator, opts \\ []) do
    start_supervised!(%{
      id: id,
      start:
        {ExecutionDeadlineWorker, :start_link,
         [[name: nil, interval_ms: 20, terminator: terminator] ++ opts]}
    })
  end

  defp await_state(id, state, attempts \\ 100)
  defp await_state(_id, state, 0), do: flunk("journal never reached #{state}")

  defp await_state(id, state, attempts) do
    case Repo.get!(TurnExecution, id) do
      %{state: ^state} = row ->
        row

      _ ->
        Process.sleep(20)
        await_state(id, state, attempts - 1)
    end
  end

  test "expiry progresses while every termination slot is blocked", c do
    owner = self()
    rows = for _ <- 1..8, do: execution(c.user, true)

    worker(:blocked_pool, fn attempt ->
      send(owner, {:termination_started, attempt.id, self()})
      receive do: (:release -> :ok)
    end)

    processes =
      for _ <- rows do
        assert_receive {:termination_started, _id, pid}, 2_000
        pid
      end

    waiting = execution(c.user)
    stopped = await_state(waiting.row.id, "stopped")
    assert stopped.attempt_id == nil
    assert Repo.get!(Turn, waiting.turn.id).limit_reason == "wall_time_limit"
    assert Enum.all?(processes, &Process.alive?/1)
    Enum.each(processes, &send(&1, :release))
    Enum.each(rows, &await_state(&1.row.id, "stopped"))
  end

  test "startup expiry progresses while every provider termination slot is blocked", c do
    owner = self()
    rows = for _ <- 1..8, do: execution(c.user, true)

    worker(:startup_independent, fn _attempt ->
      send(owner, {:blocked_provider, self()})
      receive do: (:release -> :ok)
    end)

    processes =
      for _ <- rows do
        assert_receive {:blocked_provider, pid}, 2_000
        pid
      end

    sandbox = insert_sandbox(user_id: c.user.id, status: "ready")
    parent = insert_conversation(user_id: c.user.id, sandbox: sandbox, status: "idle")
    id = Ecto.UUID.generate()

    {:ok, claim} =
      Fountain.Conversations.ActorOwnership.claim(c.user.id, parent.id, sandbox.id, id)

    startup =
      Repo.insert!(%Fountain.Conversations.ActorStartup{
        id: id,
        actor_claim_id: id,
        user_id: c.user.id,
        conversation_id: parent.id,
        sandbox_id: sandbox.id,
        deadline_at: DateTime.add(DateTime.utc_now(), -1)
      })

    assert Enum.reduce_while(1..100, false, fn _, _ ->
             if Repo.reload!(startup).state == "expired",
               do: {:halt, true},
               else:
                 (
                   Process.sleep(20)
                   {:cont, false}
                 )
           end)

    assert Repo.reload!(claim).state == "active"
    assert Enum.all?(processes, &Process.alive?/1)
    Enum.each(processes, &send(&1, :release))
    Enum.each(rows, &await_state(&1.row.id, "stopped"))
  end

  test "two coordinators authorize one termination for the same execution", c do
    owner = self()
    fixture = execution(c.user, true)

    stop = fn attempt ->
      send(owner, {:terminated, attempt.id})
      :ok
    end

    worker(:first, stop)
    worker(:second, stop)

    await_state(fixture.row.id, "stopped")
    id = fixture.row.id
    assert_received {:terminated, ^id}
    refute_received {:terminated, ^id}
    assert Repo.get!(Turn, fixture.turn.id).status == "failed"
  end

  test "a local timeout retains its attempt and restart recovery never replays it", c do
    owner = self()
    fixture = execution(c.user, true)

    worker(
      :timed_out,
      fn attempt ->
        send(owner, {:attempt, attempt, self()})
        receive do: (:never_sent -> :ok)
      end,
      job_timeout_ms: 200
    )

    assert_receive {:attempt, attempt, pid}, 2_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    assert Repo.get!(TurnExecution, fixture.row.id).state == "submitted"
    stop_supervised(:timed_out)

    # Advance only the abandoned-owner fixture, never the original deadline or nonce.
    old = DateTime.add(DateTime.utc_now(), -61, :second)

    Repo.update_all(from(e in TurnExecution, where: e.id == ^fixture.row.id),
      set: [submitted_at: old]
    )

    worker(:restarted, fn _ ->
      send(owner, :replayed)
      :ok
    end)

    recovered = await_state(fixture.row.id, "uncertain")
    assert recovered.attempt_id == attempt.attempt_id
    assert recovered.deadline_at == attempt.deadline_at
    refute_received :replayed
  end

  test "an exception from termination preserves uncertainty without provider prose", c do
    fixture = execution(c.user, true)
    worker(:failure, fn _ -> raise "private provider response" end)
    row = await_state(fixture.row.id, "uncertain")
    assert row.last_error == "termination_unconfirmed"
    assert row.attempt_id
    assert ExecutionGuard._unsafe_fenced?(fixture.conv.id)
  end

  test "coordinator shutdown waits for local tasks without confirming a remote stop", c do
    owner = self()
    fixture = execution(c.user, true)

    worker(:shutdown, fn _ ->
      send(owner, {:blocked_task, self()})
      receive do: (:never_sent -> :ok)
    end)

    assert_receive {:blocked_task, pid}, 2_000
    ref = Process.monitor(pid)
    :ok = stop_supervised(:shutdown)
    refute Process.alive?(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}
    assert Repo.get!(TurnExecution, fixture.row.id).state == "submitted"
    assert ExecutionGuard._unsafe_fenced?(fixture.conv.id)
  end

  test "an unresponsive registered conversation cannot block its deadline", c do
    owner = self()
    fixture = execution(c.user)

    actor =
      spawn(fn ->
        {:ok, _} = Horde.Registry.register(Fountain.ConversationRegistry, fixture.conv.id, nil)
        send(owner, :actor_registered)
        receive do: (:stop -> :ok)
      end)

    on_exit(fn -> Process.exit(actor, :kill) end)
    assert_receive :actor_registered

    worker(:blocked_actor, fn _ ->
      send(owner, :unexpected_termination)
      :ok
    end)

    await_state(fixture.row.id, "stopped")
    assert Process.alive?(actor)
    assert Repo.get!(Turn, fixture.turn.id).limit_reason == "wall_time_limit"
    refute_received :unexpected_termination
  end

  test "the task timeout survives abrupt coordinator death", c do
    owner = self()
    fixture = execution(c.user, true)

    coordinator =
      worker(
        :crashed_owner,
        fn _ ->
          send(owner, {:orphan_task, self()})
          receive do: (:never_sent -> :ok)
        end,
        job_timeout_ms: 300
      )

    assert_receive {:orphan_task, pid}, 2_000
    ref = Process.monitor(pid)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    assert Repo.get!(TurnExecution, fixture.row.id).state == "submitted"
    refute_received {:orphan_task, _}
  end

  test "the default termination path uses only the recorded provider and session", c do
    fixture = execution(c.user, true)
    owner = self()
    expected_name = fixture.row.sandbox_name

    expect(Managoat.Sandbox, :build_handle, fn :sprites, ^expected_name ->
      %Managoat.Sandbox.Handle{provider: :sprites, name: expected_name}
    end)

    expect(Managoat.Sandbox, :terminate_session, fn handle, "19", opts ->
      assert handle.provider == :sprites
      assert handle.name == expected_name
      assert opts == [timeout_ms: 5_000]
      send(owner, :recorded_target_stopped)
      :ok
    end)

    start_supervised!({ExecutionDeadlineWorker, name: nil, interval_ms: 20})
    await_state(fixture.row.id, "stopped")
    assert_received :recorded_target_stopped
  end
end
