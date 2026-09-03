defmodule Fountain.SandboxQueue do
  @moduledoc """
  The bounded per-tenant queue for sandbox capacity (#1033, ADR 0042).

  Fresh starts queue only when a caller opts in. Scheduled runs opt in because
  a cron firing otherwise disappears at the tenant or fleet ceiling. Requests
  wait at most one hour and each tenant holds at most ten active requests by
  default.

  The drainer claims a row before replaying it. That compare-and-swap prevents
  two replicas from starting the same request when an event-driven poke and
  the periodic backstop overlap.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Audit
  alias Fountain.Repo
  alias Fountain.SandboxQueue.Request

  @default_max_depth 10
  @default_max_wait_seconds 3600
  @claim_timeout_seconds 300
  @active_statuses ~w(queued starting)

  @doc "Queue a start or scheduled run, subject to the per-tenant depth bound."
  def enqueue(params, opts \\ []) do
    case existing_schedule_request(params) do
      %Request{} = request ->
        {:ok, request}

      nil ->
        with :ok <- check_depth(params.user_id),
             {:ok, request} <-
               %Request{}
               |> Request.changeset(Map.put_new(params, :status, "queued"))
               |> Repo.insert() do
          audited({:ok, request}, "sandbox_request.enqueued", opts)
          emit_depth(request.user_id)
          {:ok, request}
        end
    end
  end

  @doc "List a tenant's waiting requests, oldest first."
  def list_queued(user_id) when is_binary(user_id), do: Repo.all(queued_query(user_id))

  @doc "Get a request scoped to its tenant."
  def get_request(id, user_id) when is_binary(id) and is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, request_id} -> Repo.get_by(Request, id: request_id, user_id: user_id)
      :error -> nil
    end
  end

  @doc "Return a waiting request's one-based position."
  def position(%Request{status: "queued"} = request) do
    Repo.aggregate(
      from(r in Request,
        where:
          r.user_id == ^request.user_id and r.status == "queued" and
            (r.inserted_at < ^request.inserted_at or
               (r.inserted_at == ^request.inserted_at and r.id < ^request.id))
      ),
      :count
    ) + 1
  end

  def position(%Request{}), do: nil

  @doc "Cancel a request if it is still waiting."
  def cancel_request(%Request{} = request, opts \\ []) do
    now = DateTime.utc_now()

    case Repo.update_all(
           from(r in Request, where: r.id == ^request.id and r.status == "queued"),
           set: [status: "cancelled", attrs: %{}, updated_at: now]
         ) do
      {1, _} ->
        cancelled = Repo.get!(Request, request.id)
        audited({:ok, cancelled}, "sandbox_request.cancelled", opts)
        emit_depth(cancelled.user_id)
        {:ok, cancelled}

      {0, _} ->
        {:error, :not_found}
    end
  end

  @doc "Expire overdue work, then drain one tenant in FIFO claim order."
  def drain(user_id) when is_binary(user_id) do
    recover_stuck_claims(user_id)
    expired = expire_overdue(user_id)
    {started, failed} = drain_loop(user_id, {0, 0})
    emit_depth(user_id)
    %{started: started, failed: failed, expired: expired}
  end

  @doc "Tenant ids with work waiting or currently claimed."
  def user_ids_with_active_requests do
    Repo.all(
      from r in Request,
        where: r.status in ^@active_statuses,
        distinct: true,
        select: r.user_id
    )
  end

  defp drain_loop(user_id, {started, failed}) do
    case claim_next(user_id) do
      nil ->
        {started, failed}

      request ->
        case attempt(request) do
          {:ok, conversation_id} ->
            finish(request, %{status: "started", conversation_id: conversation_id})
            drain_loop(user_id, {started + 1, failed})

          {:error, {:sandbox_quota_exceeded, _}} ->
            release(request)
            {started, failed}

          {:error, :fleet_full} ->
            release(request)
            {started, failed}

          {:error, reason} ->
            finish(request, %{status: "failed", error: describe(reason)})
            drain_loop(user_id, {started, failed + 1})
        end
    end
  end

  defp claim_next(user_id) do
    case Repo.one(from r in queued_query(user_id), limit: 1) do
      nil ->
        nil

      request ->
        now = DateTime.utc_now()

        case Repo.update_all(
               from(r in Request, where: r.id == ^request.id and r.status == "queued"),
               set: [status: "starting", updated_at: now]
             ) do
          {1, _} -> Repo.get!(Request, request.id)
          {0, _} -> claim_next(user_id)
        end
    end
  end

  defp queued_query(user_id) do
    from r in Request,
      where: r.user_id == ^user_id and r.status == "queued",
      order_by: [asc: r.inserted_at, asc: r.id]
  end

  defp attempt(%Request{kind: "start"} = request) do
    attrs =
      request.attrs
      |> Map.put("user_id", request.user_id)
      |> Map.put("agent_id", request.agent_id)

    with {:ok, conversation, _outcome} <-
           Fountain.Conversations.start_or_resume_conversation(
             attrs,
             actor: "system:sandbox_queue"
           ) do
      {:ok, conversation.id}
    end
  end

  defp attempt(%Request{kind: "schedule_run", schedule_id: schedule_id} = request) do
    case Fountain.Team.Schedules.get_schedule(schedule_id, request.user_id) do
      nil ->
        {:error, :schedule_deleted}

      schedule ->
        with {:ok, conversation} <-
               Fountain.Team.Schedules.run_schedule(
                 schedule,
                 actor: "system:sandbox_queue"
               ) do
          {:ok, conversation.id}
        end
    end
  end

  defp release(%Request{} = request) do
    {1, _} =
      Repo.update_all(
        from(r in Request, where: r.id == ^request.id and r.status == "starting"),
        set: [status: "queued", updated_at: DateTime.utc_now()]
      )

    :ok
  end

  # A worker can die after its compare-and-swap and before replay finishes.
  # Both replay paths normally return in milliseconds (provisioning happens in
  # the ConversationServer), so five minutes safely identifies an abandoned
  # claim and lets the cron backstop recover it.
  defp recover_stuck_claims(user_id) do
    cutoff = DateTime.add(DateTime.utc_now(), -@claim_timeout_seconds, :second)

    Repo.update_all(
      from(r in Request,
        where: r.user_id == ^user_id and r.status == "starting" and r.updated_at < ^cutoff
      ),
      set: [status: "queued", updated_at: DateTime.utc_now()]
    )

    :ok
  end

  defp finish(%Request{} = request, attrs) do
    wait_ms = DateTime.diff(DateTime.utc_now(), request.inserted_at, :millisecond)

    {:ok, updated} =
      request
      |> Request.changeset(Map.put(attrs, :attrs, %{}))
      |> Repo.update()

    action =
      case updated.status do
        "started" -> "sandbox_request.started"
        "failed" -> "sandbox_request.failed"
      end

    audited({:ok, updated}, action, actor: "system:sandbox_queue")

    :telemetry.execute(
      [:fountain, :sandbox_queue, :completed],
      %{wait_ms: wait_ms, count: 1},
      %{status: updated.status, kind: updated.kind}
    )

    updated
  end

  defp expire_overdue(user_id) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_wait_seconds(), :second)

    overdue =
      Repo.all(
        from r in Request,
          where: r.user_id == ^user_id and r.status == "queued" and r.inserted_at < ^cutoff
      )

    Enum.count(overdue, fn request ->
      now = DateTime.utc_now()

      case Repo.update_all(
             from(r in Request, where: r.id == ^request.id and r.status == "queued"),
             set: [status: "expired", attrs: %{}, updated_at: now]
           ) do
        {1, _} ->
          expired = Repo.get!(Request, request.id)
          audited({:ok, expired}, "sandbox_request.expired", actor: "system:sandbox_queue")

          :telemetry.execute(
            [:fountain, :sandbox_queue, :completed],
            %{wait_ms: DateTime.diff(now, request.inserted_at, :millisecond), count: 1},
            %{status: "expired", kind: request.kind}
          )

          true

        {0, _} ->
          false
      end
    end)
  end

  defp check_depth(user_id) do
    depth =
      Repo.aggregate(
        from(r in Request, where: r.user_id == ^user_id and r.status in ^@active_statuses),
        :count
      )

    if depth < max_depth(), do: :ok, else: {:error, :queue_full}
  end

  defp existing_schedule_request(%{schedule_id: schedule_id, user_id: user_id})
       when is_binary(schedule_id) do
    Repo.one(
      from r in Request,
        where:
          r.user_id == ^user_id and r.schedule_id == ^schedule_id and
            r.status in ^@active_statuses,
        limit: 1
    )
  end

  defp existing_schedule_request(_params), do: nil

  defp emit_depth(user_id) do
    depth =
      Repo.aggregate(
        from(r in Request, where: r.user_id == ^user_id and r.status in ^@active_statuses),
        :count
      )

    :telemetry.execute([:fountain, :sandbox_queue, :tenant_depth], %{depth: depth}, %{})
  end

  defp audited({:ok, %Request{} = request} = ok, action, opts) do
    Audit.record(%{
      user_id: request.user_id,
      action: action,
      resource_type: "sandbox_request",
      resource_id: request.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "kind" => request.kind,
        "agent_id" => request.agent_id,
        "schedule_id" => request.schedule_id,
        "conversation_id" => request.conversation_id,
        "error" => request.error
      }
    })

    ok
  end

  defp describe({:sandbox_quota_exceeded, %{count: count, limit: limit}}),
    do: "sandbox quota: #{count}/#{limit}"

  defp describe(%Ecto.Changeset{}), do: "invalid conversation attrs"
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(reason), do: inspect(reason) |> String.slice(0, 250)

  defp max_depth,
    do: Application.get_env(:fountain, :sandbox_queue_max_depth, @default_max_depth)

  defp max_wait_seconds,
    do:
      Application.get_env(
        :fountain,
        :sandbox_queue_max_wait_seconds,
        @default_max_wait_seconds
      )
end
