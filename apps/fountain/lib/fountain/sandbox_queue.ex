defmodule Fountain.SandboxQueue do
  @moduledoc """
  The bounded per-tenant queue in front of the sandbox concurrency cap
  (#1033, ADR 0030).

  A start that hits the cap is still refused by default — queueing is an
  explicit opt-in (`queue: true` on the API create body; scheduled teammate
  runs opt in unconditionally, because a cron firing into a refusal is lost
  work nothing retries). The queue is bounded twice, and the bounds are the
  product position: within them the work completes late, past them the caller
  gets today's refusal — a queue with no ceiling turns "refused" into
  "accepted and never runs".

    * `:sandbox_queue_max_depth` — queued requests per tenant, default 10.
      At the bound, `enqueue/2` returns `{:error, :queue_full}` and the
      caller surfaces the original 429.
    * `:sandbox_queue_max_wait_seconds` — default 3600. A request older than
      this expires rather than firing hours after anyone wanted it.

  Draining is event-driven: `Conversations.update_sandbox/2` — the single
  choke point every status change goes through — pokes
  `Workers.SandboxQueueDrainer` whenever a transition frees a slot
  (terminate, fail, suspend, and the reaper's stuck-row release, all by
  construction). A five-minute cron sweep is the backstop, not the trigger.

  Fairness is per tenant twice over: the drain job is keyed by user, and the
  slot itself is won under `Quotas.with_sandbox_reservation/3`'s per-user
  advisory lock — one tenant's backlog cannot delay another's.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Audit
  alias Fountain.Repo
  alias Fountain.SandboxQueue.Request

  @default_max_depth 10
  @default_max_wait_seconds 3600

  # ── enqueue / read / cancel (tenant-facing) ───────────────────────────────

  @doc """
  Queue a request for a sandbox slot.

  `params` must carry `:user_id` and `:agent_id`, plus `:attrs` (kind
  `"start"`) or `:schedule_id` (kind `"schedule_run"`). Returns
  `{:error, :queue_full}` at the depth bound — the caller surfaces the same
  refusal it would have without the queue. A `schedule_run` for a schedule
  that already has one queued returns the existing request rather than
  stacking a duplicate per cron tick.

  The depth check is check-then-insert without a lock, deliberately: a race
  can over-admit by one, which costs a slightly deeper queue, not a sandbox
  over the cap — the cap itself is still enforced under the advisory lock at
  drain time.
  """
  def enqueue(params, opts \\ []) do
    with :ok <- check_depth(params.user_id),
         nil <- existing_schedule_request(params) do
      %Request{}
      |> Request.changeset(Map.put_new(params, :status, "queued"))
      |> Repo.insert()
      |> audited("sandbox_request.enqueued", opts)
    else
      %Request{} = existing -> {:ok, existing}
      {:error, _} = err -> err
    end
  end

  @doc "List a tenant's queued requests, oldest first (position order)."
  def list_queued(user_id) when is_binary(user_id) do
    Repo.all(queued_query(user_id))
  end

  @doc "Get one request scoped to user. Nil on wrong owner or missing id."
  def get_request(id, user_id) when is_binary(user_id) do
    Repo.get_by(Request, id: id, user_id: user_id)
  end

  @doc """
  1-based position of a queued request in its tenant's queue. Nil once the
  request is no longer queued.
  """
  def position(%Request{status: "queued"} = request) do
    # Same tie-break as queued_query/1: rows inserted within the same second
    # order by id, so the position always matches the list.
    ahead =
      Repo.aggregate(
        from(r in Request,
          where:
            r.user_id == ^request.user_id and r.status == "queued" and
              (r.inserted_at < ^request.inserted_at or
                 (r.inserted_at == ^request.inserted_at and r.id < ^request.id))
        ),
        :count
      )

    ahead + 1
  end

  def position(%Request{}), do: nil

  @doc "Withdraw a queued request. Only `queued` rows can be cancelled."
  def cancel_request(%Request{status: "queued"} = request, opts \\ []) do
    request
    |> Request.changeset(%{status: "cancelled"})
    |> Repo.update()
    |> audited("sandbox_request.cancelled", opts)
  end

  # ── drain (system-facing, called by Workers.SandboxQueueDrainer) ──────────

  @doc """
  Expire requests queued past the wait bound, then start queued requests
  oldest-first until the quota refuses or the queue is empty. Returns
  `%{started: n, failed: n, expired: n}`.

  Runs as `actor: "system:sandbox_queue"`. A request whose start fails for a
  reason other than the quota is marked failed and skipped — one broken
  request must not head-of-line-block the tenant's queue. The quota error
  stops the drain: the slot this run was poked about is taken.
  """
  def drain(user_id) when is_binary(user_id) do
    expired = expire_overdue(user_id)
    {started, failed} = drain_loop(user_id, {0, 0})
    %{started: started, failed: failed, expired: expired}
  end

  @doc "Tenant ids with anything queued — the backstop sweep's worklist."
  def user_ids_with_queued do
    Repo.all(from r in Request, where: r.status == "queued", distinct: true, select: r.user_id)
  end

  defp drain_loop(user_id, {started, failed}) do
    case next_queued(user_id) do
      nil ->
        {started, failed}

      request ->
        case attempt(request) do
          {:ok, conversation_id} ->
            finish(request, %{status: "started", conversation_id: conversation_id})
            drain_loop(user_id, {started + 1, failed})

          {:error, {:sandbox_quota_exceeded, _}} ->
            {started, failed}

          {:error, reason} ->
            finish(request, %{status: "failed", error: describe(reason)})
            drain_loop(user_id, {started, failed + 1})
        end
    end
  end

  defp next_queued(user_id) do
    Repo.one(from r in queued_query(user_id), limit: 1)
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

    with {:ok, conv} <-
           Fountain.Conversations.start_conversation(attrs, actor: "system:sandbox_queue") do
      {:ok, conv.id}
    end
  end

  defp attempt(%Request{kind: "schedule_run", schedule_id: schedule_id} = request) do
    case Fountain.Team.Schedules.get_schedule(schedule_id, request.user_id) do
      nil ->
        # The schedule was deleted while its run waited; there is nothing to
        # run and nothing to blame.
        {:error, :schedule_deleted}

      schedule ->
        with {:ok, conv} <-
               Fountain.Team.Schedules.run_schedule(schedule, actor: "system:sandbox_queue") do
          {:ok, conv.id}
        end
    end
  end

  defp finish(%Request{} = request, attrs) do
    {:ok, updated} = request |> Request.changeset(attrs) |> Repo.update()

    action =
      case attrs.status do
        "started" -> "sandbox_request.started"
        "failed" -> "sandbox_request.failed"
      end

    audited({:ok, updated}, action, actor: "system:sandbox_queue")
    updated
  end

  defp expire_overdue(user_id) do
    cutoff =
      DateTime.utc_now()
      |> DateTime.add(-max_wait_seconds(), :second)
      |> DateTime.truncate(:second)

    overdue =
      Repo.all(
        from r in Request,
          where: r.user_id == ^user_id and r.status == "queued" and r.inserted_at < ^cutoff
      )

    Enum.each(overdue, fn request ->
      {:ok, updated} = request |> Request.changeset(%{status: "expired"}) |> Repo.update()
      audited({:ok, updated}, "sandbox_request.expired", actor: "system:sandbox_queue")
    end)

    length(overdue)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp check_depth(user_id) do
    depth =
      Repo.aggregate(
        from(r in Request, where: r.user_id == ^user_id and r.status == "queued"),
        :count
      )

    if depth < max_depth(), do: :ok, else: {:error, :queue_full}
  end

  defp existing_schedule_request(%{schedule_id: schedule_id, user_id: user_id})
       when is_binary(schedule_id) do
    Repo.one(
      from r in Request,
        where: r.user_id == ^user_id and r.schedule_id == ^schedule_id and r.status == "queued",
        limit: 1
    )
  end

  defp existing_schedule_request(_params), do: nil

  # The request row is the resource; `attrs` never appears in the trail (it
  # is the caller's own prompt and settings, not something audit re-records).
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

  defp audited(other, _action, _opts), do: other

  defp describe({:sandbox_quota_exceeded, %{count: c, limit: l}}), do: "sandbox quota: #{c}/#{l}"
  defp describe(%Ecto.Changeset{}), do: "invalid conversation attrs"
  defp describe(reason) when is_atom(reason), do: to_string(reason)
  defp describe(reason), do: inspect(reason)

  defp max_depth, do: Application.get_env(:fountain, :sandbox_queue_max_depth, @default_max_depth)

  defp max_wait_seconds,
    do:
      Application.get_env(
        :fountain,
        :sandbox_queue_max_wait_seconds,
        @default_max_wait_seconds
      )
end
