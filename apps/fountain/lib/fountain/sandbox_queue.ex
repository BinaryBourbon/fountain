defmodule Fountain.SandboxQueue do
  @moduledoc """
  The bounded per-tenant queue for sandbox capacity (#1033, ADR 0042).

  A start reaches a capacity limit two ways: the tenant's own cap, funded by
  its credit balance under ADR 0031, and `SANDBOX_FLEET_CEILING` across the
  whole deployment. `Quotas.with_sandbox_reservation/3` refuses both
  immediately, which is the right answer for a caller that can retry and the
  wrong one for a cron firing with nobody there to retry it.

  This module holds that work instead. It never raises a limit: the queue
  delays admission and every replay re-enters the same reservation, the same
  credit gate and the same platform-inference gate.

  Bounded twice. A tenant holds at most `SANDBOX_QUEUE_MAX_DEPTH` active
  requests, and a request waits at most `SANDBOX_QUEUE_MAX_WAIT_SECONDS`.
  Beyond the depth bound the caller keeps its immediate capacity error.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Audit
  alias Fountain.Repo
  alias Fountain.SandboxQueue.Request

  @default_max_depth 10

  # One source of truth. `Request.active_statuses/0` is what the ops gauge
  # reads too, and two copies would let the depth bound and the gauge disagree
  # silently if a status were ever added.
  @active_statuses Request.active_statuses()

  # Its own advisory-lock namespace. The depth bound counts rows in
  # `sandbox_requests` and has nothing to serialize against a sandbox
  # reservation, and every namespace here hashes a different kind of id into
  # the same 32 bits: sharing one would let a `phash2` collision between a
  # user and a sandbox block an unrelated writer. Taken: 4315
  # `Fountain.Quotas`, 4316 `Conversations`, 4331 `Fountain.Connections`.
  @lock_namespace 4317

  @doc """
  Queue a start or a scheduled run, subject to the per-tenant depth bound.

  `params` is a map the caller builds key by key — never a request body cast
  wholesale. Returns `{:error, :queue_full}` at the depth bound, which the
  caller turns back into the capacity error it was about to send.

  A `schedule_run` is deduplicated against the schedule's own live request, so
  a cron that keeps firing while the first one waits does not stack ten copies
  of the same run. That dedup wins over the depth bound: it removes a row
  rather than adding one.
  """
  def enqueue(params, opts \\ []) do
    with {:ok, outcome} <- insert_bounded(params) do
      case outcome do
        # The schedule already had a live request. Nothing was written, so
        # nothing is recorded: a trail that logs an attempt as a change is
        # worse than no trail (ADR 0013).
        {:deduplicated, request} ->
          {:ok, request}

        # Audited outside the transaction: `Audit.record/1` is best-effort
        # by rescuing, and a rescue does not survive a transaction — a
        # failed audit insert would abort the enclosing one and take the
        # request with it.
        {:inserted, request} ->
          audited(request, "sandbox_request.enqueued", opts)
          emit_depth(request.user_id)
          {:ok, request}
      end
    end
  end

  @doc """
  The tenant's live request for a schedule, if it has one.

  What lets a surface say "waiting for a free slot" rather than repeating the
  capacity error a replay just met again.
  """
  def schedule_request(user_id, schedule_id)
      when is_binary(user_id) and is_binary(schedule_id) do
    existing_schedule_request(%{user_id: user_id, schedule_id: schedule_id})
  end

  # The depth bound is a check followed by an insert, so it needs the same
  # protection `Quotas.with_sandbox_reservation/3` gives the sandbox cap: two
  # requests that both read "room for one more" at the last slot is precisely
  # how #330 got past that cap before its advisory lock existed.
  #
  # The schedule dedup reads under the same lock, for the same reason: two
  # firings of one schedule that both read "no live request" would both insert,
  # which is the stacking the dedup exists to prevent.
  defp insert_bounded(params) do
    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @lock_namespace,
        :erlang.phash2(params.user_id)
      ])

      case existing_schedule_request(params) do
        %Request{} = request ->
          {:deduplicated, request}

        nil ->
          with :ok <- check_depth(params.user_id),
               {:ok, request} <-
                 %Request{}
                 |> Request.changeset(Map.put_new(params, :status, "queued"))
                 |> Repo.insert() do
            {:inserted, request}
          else
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
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

  @doc """
  A waiting request's one-based position.

  Counts claimed (`starting`) rows as well as waiting ones: a request being
  replayed right now is still ahead of this one, and leaving it out reports
  `position: 1` to a caller that has someone in front of it. `nil` once the
  request is no longer waiting.
  """
  def position(%Request{status: "queued"} = request) do
    Repo.aggregate(
      from(r in Request,
        where:
          r.user_id == ^request.user_id and r.status in ^@active_statuses and
            (r.inserted_at < ^request.inserted_at or
               (r.inserted_at == ^request.inserted_at and r.id < ^request.id))
      ),
      :count
    ) + 1
  end

  def position(%Request{}), do: nil

  @doc """
  Cancel a request if it is still waiting.

  A compare-and-swap, not a read-then-write: the drainer may have claimed the
  row between the caller's fetch and this call, and a cancellation that
  reached a `starting` row would abandon a start already in flight.
  """
  def cancel_request(%Request{} = request, opts \\ []) do
    case terminate(request.id, "queued", %{status: "cancelled", attrs: %{}}) do
      {:ok, cancelled} ->
        audited(cancelled, "sandbox_request.cancelled", opts)
        emit_depth(cancelled.user_id)
        {:ok, cancelled}

      :stale ->
        {:error, :not_found}
    end
  end

  # One compare-and-swap from `expected` to whatever `attrs` says, returning
  # the row it wrote or `:stale` when somebody else moved it first. Every
  # transition out of a live status goes through here, so no path in this
  # module writes a status with a blind `Repo.update/1`.
  defp terminate(id, expected, attrs) do
    now = DateTime.utc_now()
    sets = attrs |> Map.to_list() |> Keyword.put(:updated_at, now)

    case Repo.update_all(
           from(r in Request, where: r.id == ^id and r.status == ^expected),
           set: sets
         ) do
      {1, _} -> {:ok, Repo.get!(Request, id)}
      {0, _} -> :stale
    end
  end

  defp queued_query(user_id) do
    from r in Request,
      where: r.user_id == ^user_id and r.status == "queued",
      order_by: [asc: r.inserted_at, asc: r.id]
  end

  defp check_depth(user_id) do
    if active_depth(user_id) < max_depth(), do: :ok, else: {:error, :queue_full}
  end

  defp active_depth(user_id) do
    Repo.aggregate(
      from(r in Request, where: r.user_id == ^user_id and r.status in ^@active_statuses),
      :count
    )
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
    :telemetry.execute(
      [:fountain, :sandbox_queue, :tenant_depth],
      %{depth: active_depth(user_id)},
      %{}
    )
  end

  # Keys, sizes and provenance — never the prompt, which lives in `attrs` and
  # is erased at every terminal transition anyway.
  defp audited(%Request{} = request, action, opts) do
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

    request
  end

  defp max_depth,
    do: Application.get_env(:fountain, :sandbox_queue_max_depth, @default_max_depth)
end
