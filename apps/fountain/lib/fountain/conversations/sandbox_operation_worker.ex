defmodule Fountain.Conversations.SandboxOperationWorker do
  @moduledoc """
  Recover fixed sandbox operations independently of conversation actors.

  Disabled by default. Separate cleanup and observation pools keep blocked
  provider calls from starving submission recovery. Every task owns its timeout,
  including after coordinator failure. Unknown creates are never probed,
  adopted, or replayed. Execution controls remain disabled too.
  """
  use GenServer

  alias Fountain.Conversations.SandboxOperations

  @pool_size 4
  @batch_size 100
  @submission_age_seconds 180
  @recovery_interval_seconds 60
  @job_timeout_ms 35_000

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, if(name, do: [name: name], else: []))
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    send(self(), :tick)

    {:ok,
     %{
       jobs: %{},
       interval: Keyword.get(opts, :interval_ms, 5_000),
       timeout: Keyword.get(opts, :job_timeout_ms, @job_timeout_ms),
       supervisor: Keyword.get(opts, :task_supervisor, Fountain.TaskSupervisor),
       probe: Keyword.get(opts, :probe, &Managoat.Sandbox.get/1)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    state = start_single(state, :scan, &scan/0)

    state =
      start_single(state, :abandoned, fn ->
        cutoff = DateTime.add(DateTime.utc_now(), -@submission_age_seconds, :second)
        # Ownership: system recovery of durable intent; this grants no provider call.
        SandboxOperations._unsafe_recover_submissions(cutoff, @batch_size)
      end)

    {:noreply, state}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: :scan}, jobs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | jobs: jobs}
        state = start_candidates(state, :cleanup, result.cleanup)
        {:noreply, start_candidates(state, :reconcile, result.reconcile)}

      {_job, jobs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | jobs: jobs}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # The journal, not the task exit, decides whether a provider operation ended.
    {:noreply, %{state | jobs: Map.delete(state.jobs, ref)}}
  end

  @impl true
  def terminate(_reason, state) do
    state.jobs
    |> Enum.map(fn {_ref, job} -> job.task end)
    |> Task.yield_many(timeout: 1_000)
    |> Enum.each(fn {task, result} ->
      if is_nil(result), do: Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end

  defp scan do
    # Ownership: system-wide candidate read; each claim rechecks the retained binding.
    SandboxOperations._unsafe_recovery_candidates(recovery_cutoff(), @batch_size)
  end

  defp start_single(state, kind, fun) do
    if Enum.any?(state.jobs, fn {_ref, job} -> job.kind == kind end),
      do: state,
      else: start_job(state, kind, nil, fun)
  end

  defp start_candidates(state, kind, ids) do
    busy = MapSet.new(state.jobs, fn {_ref, job} -> job.id end)
    used = Enum.count(state.jobs, fn {_ref, job} -> job.kind == kind end)

    ids
    |> Enum.reject(&MapSet.member?(busy, &1))
    |> Enum.take(@pool_size - used)
    |> Enum.reduce(state, fn id, state ->
      start_job(state, kind, id, fn -> recover(kind, id, state.probe) end)
    end)
  end

  defp recover(:cleanup, id, _probe) do
    # Ownership: system-selected creation id; the context rechecks current holders and owner.
    SandboxOperations._unsafe_recover_creation(id, recovery_cutoff())
  end

  defp recover(:reconcile, id, probe) do
    # Ownership: system-selected delete intent; the context refuses other actions or bindings.
    SandboxOperations._unsafe_reconcile_destroy(id, recovery_cutoff(), probe)
  end

  defp recovery_cutoff,
    do: DateTime.add(DateTime.utc_now(), -@recovery_interval_seconds, :second)

  defp start_job(state, kind, id, fun) do
    timeout = state.timeout

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        {:ok, timer} = :timer.kill_after(timeout)

        try do
          fun.()
        after
          :timer.cancel(timer)
        end
      end)

    %{state | jobs: Map.put(state.jobs, task.ref, %{task: task, kind: kind, id: id})}
  end
end
