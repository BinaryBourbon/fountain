defmodule Fountain.Conversations.ExecutionDeadlineWorker do
  @moduledoc """
  Drives the execution journal independently of conversation mailboxes.

  Turn expiry, startup expiry and termination have separate bounded task pools. A blocked provider
  call cannot occupy the slots that expire other turns. Every task has its own
  hard local timeout, including after this coordinator dies. Killing a local
  task says nothing about remote termination: the journal retains submitted
  intent, and recovery marks an abandoned attempt uncertain without replaying it.
  Startup expiry scans saved outcomes after actor or coordinator loss; it revokes
  only the original conversation's access and retains unresolved ownership.

  Public admission remains disabled until trusted identity and all lifecycle
  paths are integrated. This worker alone does not enable bounded execution.
  """
  use GenServer

  alias Fountain.Conversations.{ActorStartups, ExecutionGuard}

  @pool_size 8
  @batch_size 100
  @job_timeout_ms 10_000
  @recovery_after_seconds 60
  @providers %{"sprites" => :sprites, "runner" => :runner, "e2b" => :e2b, "daytona" => :daytona}

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
       startup_after: nil,
       interval: Keyword.get(opts, :interval_ms, 1_000),
       timeout: Keyword.get(opts, :job_timeout_ms, @job_timeout_ms),
       supervisor: Keyword.get(opts, :task_supervisor, Fountain.TaskSupervisor),
       terminator: Keyword.get(opts, :terminator, &terminate_session/1)
     }}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.interval)
    state = start_single(state, :scan, &scan/0)

    state =
      start_single(state, :recovery, fn ->
        cutoff = DateTime.add(DateTime.utc_now(), -@recovery_after_seconds, :second)
        # ownership: system recovery of persisted intents; this grants no provider write.
        ExecutionGuard._unsafe_recover_submissions(cutoff)
      end)

    {:noreply, start_startup_scan(state)}
  end

  def handle_info({ref, result}, state) when is_reference(ref) do
    case Map.pop(state.jobs, ref) do
      {nil, _} ->
        {:noreply, state}

      {%{kind: :scan}, jobs} ->
        Process.demonitor(ref, [:flush])
        state = %{state | jobs: jobs}
        state = start_candidates(state, :expiry, result.due)
        {:noreply, start_candidates(state, :termination, result.ready)}

      {%{kind: :startup_scan}, jobs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, start_startups(%{state | jobs: jobs}, result)}

      {_job, jobs} ->
        Process.demonitor(ref, [:flush])
        {:noreply, %{state | jobs: jobs}}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    # The durable claim, if any, remains submitted until recovery. Never infer
    # a remote result from a local exit or grant another provider write here.
    {:noreply, %{state | jobs: Map.delete(state.jobs, ref)}}
  end

  @impl true
  def terminate(_reason, state) do
    # Give short journal writes time to finish before forcing local shutdown.
    # A blocked provider still gets only this bounded grace, never confirmation.
    state.jobs
    |> Enum.map(fn {_ref, job} -> job.task end)
    |> Task.yield_many(timeout: 1_000)
    |> Enum.each(fn {task, result} ->
      if is_nil(result), do: Task.shutdown(task, :brutal_kill)
    end)

    :ok
  end

  defp scan do
    now = DateTime.utc_now()

    # ownership: system-wide journal scan; these reads grant no provider authority.
    %{
      due: ExecutionGuard._unsafe_due_deadlines(now, @batch_size),
      ready: ExecutionGuard._unsafe_ready_terminations(@batch_size)
    }
  end

  # Startup expiry has its own pool. Scan only when a slot is free, and advance
  # past attempts actually dispatched so repeated lock failures cannot starve
  # later rows. The cursor is scheduling state, never an ownership decision.
  defp start_startup_scan(state) do
    used = Enum.count(state.jobs, fn {_ref, job} -> job.kind == :startup_expiry end)

    if used < @pool_size do
      start_single(state, :startup_scan, fn ->
        ActorStartups._unsafe_due(DateTime.utc_now(), @batch_size, state.startup_after)
      end)
    else
      state
    end
  end

  defp start_startups(state, ids) do
    active = for {_ref, %{kind: :startup_expiry, id: id}} <- state.jobs, do: id
    candidates = ids |> Enum.reject(&(&1 in active)) |> Enum.take(@pool_size - length(active))
    cursor = List.last(candidates) || List.last(ids)

    # ownership: the system scan selected saved startup IDs; recovery rechecks
    # each immutable tenant/parent/machine/actor binding under its original locks.
    Enum.reduce(candidates, %{state | startup_after: cursor}, fn id, state ->
      start_job(state, :startup_expiry, id, fn -> ActorStartups._unsafe_recover(id) end)
    end)
  end

  defp start_single(state, kind, fun) do
    if Enum.any?(state.jobs, fn {_ref, job} -> job.kind == kind end),
      do: state,
      else: start_job(state, kind, nil, fun)
  end

  defp start_candidates(state, kind, ids) do
    busy =
      MapSet.new(
        for {_ref, %{kind: kind, id: id}} <- state.jobs, kind in [:expiry, :termination], do: id
      )

    used = Enum.count(state.jobs, fn {_ref, job} -> job.kind == kind end)

    ids
    |> Enum.reject(&MapSet.member?(busy, &1))
    |> Enum.take(@pool_size - used)
    |> Enum.reduce(state, fn id, state ->
      fun =
        case kind do
          # ownership: system scan selected this journal's immutable turn binding.
          # Do not pass the scan's pre-lock clock to the authority check.
          :expiry -> fn -> ExecutionGuard._unsafe_expire(id) end
          :termination -> fn -> stop(id, state.terminator) end
        end

      start_job(state, kind, id, fun)
    end)
  end

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

  defp stop(id, terminator) do
    # ownership: system-selected journal id; the claim rechecks tenant and sandbox binding.
    case ExecutionGuard._unsafe_claim_termination(id) do
      {:ok, %{permitted: true, execution: attempt}} ->
        result = call_terminator(terminator, attempt)
        ExecutionGuard._unsafe_record_termination(id, attempt.attempt_id, result)

      other ->
        other
    end
  end

  defp call_terminator(terminator, attempt) do
    terminator.(attempt)
  rescue
    _ -> {:error, :termination_unconfirmed}
  catch
    _, _ -> {:error, :termination_unconfirmed}
  end

  defp terminate_session(attempt) do
    with {:ok, provider} <- Map.fetch(@providers, attempt.provider) do
      handle = Managoat.Sandbox.build_handle(provider, attempt.sandbox_name)
      Managoat.Sandbox.terminate_session(handle, attempt.provider_session_id, timeout_ms: 5_000)
    else
      :error -> {:error, :not_supported}
    end
  end
end
