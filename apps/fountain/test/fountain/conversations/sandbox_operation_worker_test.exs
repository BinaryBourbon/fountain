defmodule Fountain.Conversations.SandboxOperationWorkerTest do
  use Fountain.DataCase, async: false
  use Mimic

  setup :set_mimic_global

  alias Fountain.Conversations.{SandboxOperation, SandboxOperations, SandboxOperationWorker}
  alias Managoat.Sandbox.Handle

  setup do
    %{user: insert_verified_user()}
  end

  defp creation(user, orphan? \\ true) do
    sandbox = insert_sandbox(user_id: user.id, status: "pending", mode: "ephemeral")
    parent = insert_conversation(user_id: user.id, sandbox: sandbox)
    {:ok, operation} = SandboxOperations._unsafe_submit_create(sandbox, parent)
    handle = %Handle{provider: :sprites, name: sandbox.sprite_name, instance_id: sandbox.id}
    {:ok, _} = SandboxOperations._unsafe_complete_create(operation.id, {:ok, handle})
    if orphan?, do: Repo.delete!(parent)
    %{sandbox: sandbox, operation: operation}
  end

  defp uncertain_delete(user) do
    c = creation(user, false)
    {:ok, deletion} = SandboxOperations._unsafe_submit_destroy(c.sandbox)
    {:ok, _} = SandboxOperations._unsafe_mark_uncertain(deletion.id)
    Map.put(c, :deletion, deletion)
  end

  defp worker(id, opts \\ []) do
    start_supervised!(%{
      id: id,
      start: {SandboxOperationWorker, :start_link, [[name: nil, interval_ms: 20] ++ opts]}
    })
  end

  defp await(fun, attempts \\ 100)
  defp await(_fun, 0), do: flunk("recovery condition never became true")

  defp await(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      await(fun, attempts - 1)
    end
  end

  test "application does not start the recovery worker by default" do
    refute Application.get_env(:fountain, :sandbox_operation_worker_enabled, false)
    refute Process.whereis(SandboxOperationWorker)
  end

  test "two coordinators grant only one deletion for an orphan", c do
    fixture = creation(c.user)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ ->
      send(owner, :deleted)
      :ok
    end)

    worker(:first)
    worker(:second)
    await(fn -> not Repo.reload!(fixture.operation).holds_slot end)
    assert_received :deleted
    refute_received :deleted
  end

  test "blocked cleanup slots cannot starve submission recovery or deletion observations", c do
    owner = self()
    fixtures = for _ <- 1..4, do: creation(c.user)

    stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ ->
      send(owner, {:deleting, self()})
      receive do: (:finish -> :ok)
    end)

    worker(:blocked, probe: fn _ -> {:error, :not_found} end)

    blocked =
      for _ <- fixtures do
        assert_receive {:deleting, pid}, 2_000
        pid
      end

    sandbox = insert_sandbox(user_id: c.user.id, status: "pending")
    parent = insert_conversation(user_id: c.user.id, sandbox: sandbox)
    {:ok, pending} = SandboxOperations._unsafe_submit_create(sandbox, parent)
    old = DateTime.add(DateTime.utc_now(), -200, :second)

    Repo.update_all(from(o in SandboxOperation, where: o.id == ^pending.id),
      set: [submitted_at: old]
    )

    unknown_delete = uncertain_delete(c.user)

    await(fn -> Repo.reload!(pending).state == "uncertain" end)
    await(fn -> Repo.reload!(unknown_delete.deletion).state == "confirmed" end)
    assert Repo.reload!(pending).holds_slot
    assert Enum.all?(blocked, &Process.alive?/1)
    Enum.each(blocked, &send(&1, :finish))
    Enum.each(fixtures, fn f -> await(fn -> not Repo.reload!(f.operation).holds_slot end) end)
  end

  test "a timed-out cleanup survives restart as an observation, never another delete", c do
    fixture = creation(c.user)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ ->
      send(owner, {:delete, self()})
      receive do: (:never -> :ok)
    end)

    worker(:lost, job_timeout_ms: 200)
    assert_receive {:delete, pid}, 2_000
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 2_000
    stop_supervised(:lost)

    deletion =
      Repo.get_by!(SandboxOperation, creation_id: fixture.operation.id, action: "destroy")

    assert deletion.state == "submitted"
    old = DateTime.add(DateTime.utc_now(), -200, :second)

    Repo.update_all(from(o in SandboxOperation, where: o.id == ^deletion.id),
      set: [submitted_at: old]
    )

    worker(:replacement,
      probe: fn _ ->
        send(owner, :observed)
        {:ok, %{}}
      end
    )

    await(fn -> Repo.reload!(deletion).state == "uncertain" end)
    assert_receive :observed, 2_000
    refute_received {:delete, _}
    assert Repo.reload!(fixture.operation).holds_slot
  end

  test "cleanup task keeps its timeout after the coordinator crashes", c do
    fixture = creation(c.user)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :destroy_once, fn _, _ ->
      send(owner, {:delete, self()})
      receive do: (:never -> :ok)
    end)

    {:ok, coordinator} =
      GenServer.start(SandboxOperationWorker, name: nil, interval_ms: 20, job_timeout_ms: 300)

    on_exit(fn -> if Process.alive?(coordinator), do: Process.exit(coordinator, :kill) end)
    assert_receive {:delete, task}, 2_000
    ref = Process.monitor(task)
    Process.exit(coordinator, :kill)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 2_000
    assert Repo.reload!(fixture.operation).holds_slot

    assert Repo.get_by!(SandboxOperation, creation_id: fixture.operation.id, action: "destroy").state ==
             "submitted"
  end

  test "observation timeout retains capacity and prevents immediate reprobe", c do
    fixture = uncertain_delete(c.user)
    owner = self()

    worker(:observer,
      job_timeout_ms: 200,
      probe: fn _ ->
        send(owner, {:probe, self()})
        receive do: (:never -> {:error, :not_found})
      end
    )

    assert_receive {:probe, task}, 2_000
    ref = Process.monitor(task)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}, 2_000
    stop_supervised(:observer)
    assert Repo.reload!(fixture.operation).holds_slot
    assert Repo.reload!(fixture.deletion).state == "uncertain"
    assert Repo.reload!(fixture.deletion).recovery_checked_at
    refute_received {:probe, _}
  end
end
