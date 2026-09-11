defmodule Fountain.Conversations.ExecutionGuard do
  @moduledoc """
  Durable arbitration between a bounded turn finishing and its deadline expiring.

  Conversation then journal row locks serialize registration, completion, and
  termination claims. Provider I/O is deliberately outside these transactions:
  `claim_termination` persists an attempt before handing a worker permission for
  exactly one write. A lost reply leaves a fence; it never grants another write.

  These unscoped operations are for an already-owned conversation server or the
  system deadline worker. Registration derives ownership from persisted parents;
  callers cannot supply a tenant, sandbox name, or provider. A provider-issued
  session identity must be bound by the trusted command transport, never stdout.

  This module is a journal primitive. API admission, transport binding, deadline
  scheduling and lifecycle integration must use it before enforcement is shipped.
  """
  import Ecto.Query

  alias Fountain.{Audit, Repo}
  alias Fountain.Conversations.{Conversation, ExecutionLimits, Sandbox, Turn, TurnExecution}
  alias Fountain.Conversations.{DeadlineEvents, LogEvent}

  @fenced ~w(awaiting_identity ready submitted uncertain)
  @terminal_turns ~w(completed failed interrupted)

  @doc """
  Register a bounded turn's journal inside the caller's admission transaction.

  Deliberately a step rather than a replacement for
  `Conversations._unsafe_create_turn_on_sandbox/3`. That function already holds
  the per-sandbox advisory lock, takes `FOR UPDATE` on the parent so the
  allowance's foreign key cannot deadlock against it (#1790), proves the
  conversation is still attached to a **non-terminal** sandbox owned by the same
  tenant (#1761, #1764), and rechecks the saved allowance under those locks.
  Re-implementing admission here would drop every one of those; adding a step to
  it keeps them and still commits the journal with the turn.

  A turn with no configured allowance registers nothing: the journal is for
  bounded turns, and an unbounded turn has nothing to expire.
  """
  def _unsafe_register_bounded(turn, sandbox_id, conv) do
    limits = resolve_turn_limits(conv)

    if map_size(limits) == 0 do
      :unbounded
    else
      # A journal row needs an absolute deadline. A request carrying only SDK
      # controls cannot be admitted by inventing an allowance nobody asked for.
      unless Map.has_key?(limits, "wall_time_seconds"),
        do: Repo.rollback({:execution_limits_invalid, "wall_time_seconds_required"})

      sandbox = Repo.get(Sandbox, sandbox_id) || Repo.rollback(:sandbox_not_found)
      if sandbox.provider != "sprites", do: Repo.rollback(:provider_not_supported)

      case Managoat.Runtimes.ACP.execution_limits(
             conv.runtime,
             ExecutionLimits.sdk_options(limits)
           ) do
        {:ok, _} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      if is_nil(turn.started_at), do: Repo.rollback(:turn_not_started)
      deadline = DateTime.add(turn.started_at, limits["wall_time_seconds"], :second)

      case _unsafe_register(turn.id, Ecto.UUID.generate(), deadline) do
        {:ok, execution} -> {:bounded, execution}
        {:error, reason} -> Repo.rollback(reason)
      end
    end
  end

  @doc "Whether an unresolved bounded execution fences this conversation. Caller holds the parent lock."
  def _unsafe_open_execution?(conversation_id), do: open_execution?(conversation_id)

  @doc "Refuse a new prompt or wake while an earlier bounded execution is unresolved."
  def _unsafe_admission_gate(conversation_id) do
    transaction(fn ->
      lock_parent(conversation_id) || Repo.rollback(:not_found)
      if open_execution?(conversation_id), do: Repo.rollback(:execution_fenced)
      {:ok, nil, nil}
    end)
    |> case do
      {:ok, :ok} -> :ok
      error -> error
    end
  end

  @doc "Persist cancellation without waiting for the conversation actor or provider."
  def _unsafe_interrupt(conversation_id) do
    transaction(fn ->
      lock_parent(conversation_id) || Repo.rollback(:not_found)

      # `limit: 1` is exact rather than a guess: `turn_executions_open_conversation_index`
      # is a unique index on `conversation_id` partial to
      # `state NOT IN ('completed','stopped')`, so a conversation has at most
      # one open journal by construction. The `order_by` only makes the choice
      # deterministic if that invariant were ever dropped.
      execution =
        Repo.one(
          from e in TurnExecution,
            where:
              e.conversation_id == ^conversation_id and e.state not in ["completed", "stopped"],
            order_by: [desc: e.inserted_at],
            limit: 1,
            lock: "FOR UPDATE"
        )

      if execution do
        lock_turn(execution.turn_id)
        {decision, changed, event} = complete(execution, "interrupted", DateTime.utc_now())
        {{:bounded, decision.execution.id}, changed, event}
      else
        {:unbounded, nil, nil}
      end
    end)
  end

  @doc "Find the immutable journal for an already-owned actor's turn."
  def _unsafe_for_turn(turn_id), do: Repo.get_by(TurnExecution, turn_id: turn_id)

  def _unsafe_register(turn_id, connection_id, %DateTime{} = deadline_at, opts \\ []) do
    transaction(fn ->
      turn = Repo.get(Turn, turn_id) || Repo.rollback(:not_found)
      observed = Repo.get(Conversation, turn.conversation_id) || Repo.rollback(:not_found)
      lock_sandbox(observed.sandbox_id)
      conv = lock_parent(turn.conversation_id) || Repo.rollback(:not_found)
      if conv.sandbox_id != observed.sandbox_id, do: Repo.rollback(:ownership_changed)
      turn = lock_turn(turn_id) || Repo.rollback(:not_found)
      if turn.conversation_id != conv.id, do: Repo.rollback(:ownership_changed)
      existing = lock_execution_by_turn(turn_id)
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        existing && existing.connection_id == connection_id &&
            DateTime.compare(existing.deadline_at, deadline_at) == :eq ->
          {existing, nil, nil}

        existing ->
          Repo.rollback(:immutable_execution)

        turn.status != "running" ->
          Repo.rollback(:turn_not_running)

        DateTime.compare(deadline_at, now) != :gt ->
          Repo.rollback(:deadline_expired)

        open_execution?(conv.id) ->
          Repo.rollback(:execution_fenced)

        true ->
          sandbox = Repo.get(Sandbox, conv.sandbox_id) || Repo.rollback(:sandbox_not_found)
          if sandbox.user_id != conv.user_id, do: Repo.rollback(:ownership_changed)
          if sandbox.status != "ready", do: Repo.rollback(:sandbox_not_ready)

          # Bounded turns never inherit a warm process: it may retain background
          # work or SDK allowances from its previous prompt.
          if prior_connection(connection_id), do: Repo.rollback(:connection_retired)

          limits = resolve_turn_limits(conv)
          enforce_deadline_ceiling!(turn, deadline_at, limits)

          attrs = %{
            execution_limits: limits,
            turn_id: turn.id,
            conversation_id: conv.id,
            user_id: conv.user_id,
            sandbox_id: sandbox.id,
            sandbox_name: sandbox.sprite_name,
            provider: sandbox.provider,
            connection_id: connection_id,
            deadline_at: deadline_at
          }

          case %TurnExecution{} |> TurnExecution.changeset(attrs) |> Repo.insert() do
            {:ok, execution} -> {execution, execution, "registered"}
            {:error, changeset} -> Repo.rollback(changeset)
          end
      end
    end)
  end

  @doc "Record one spawn intent before opening its transport; an unknown spawn is never replayed."
  def _unsafe_claim_spawn(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "active" or not is_nil(execution.provider_session_id) or
            not is_nil(execution.spawn_submitted_at) ->
          Repo.rollback(:spawn_not_ready)

        DateTime.compare(now, execution.deadline_at) != :lt ->
          Repo.rollback(:deadline_expired)

        not match?(%Turn{status: "running"}, Repo.get(Turn, execution.turn_id)) ->
          Repo.rollback(:turn_not_running)

        not current_binding?(execution) ->
          Repo.rollback(:ownership_changed)

        true ->
          updated = update!(execution, %{spawn_submitted_at: now})
          {updated, updated, "spawn_submitted"}
      end
    end)
  end

  def _unsafe_bind_identity(id, connection_id, session_id) do
    if valid_session_id?(session_id) do
      with_execution(id, fn execution ->
        cond do
          execution.connection_id != connection_id ->
            Repo.rollback(:stale_connection)

          execution.provider_session_id == session_id ->
            {execution, nil, nil}

          execution.state not in [
            "active",
            "awaiting_identity",
            "ready",
            "submitted",
            "uncertain"
          ] ->
            Repo.rollback(:execution_closed)

          not is_nil(execution.provider_session_id) ->
            updated =
              update!(execution, %{state: "uncertain", last_error: "conflicting_identity"})

            fail_running_turn(execution.turn_id, DateTime.utc_now())
            {updated, updated, "identity_uncertain"}

          execution.state not in ["active", "awaiting_identity"] ->
            Repo.rollback(:execution_closed)

          is_nil(execution.spawn_submitted_at) ->
            Repo.rollback(:spawn_not_submitted)

          true ->
            state = if execution.state == "awaiting_identity", do: "ready", else: "active"
            updated = update!(execution, %{provider_session_id: session_id, state: state})
            {updated, updated, "identity_bound"}
        end
      end)
    else
      {:error, :invalid_session_id}
    end
  end

  @doc "Authorize an immediate write to the original identified execution."
  def _unsafe_authorize_write(id, connection_id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.connection_id != connection_id ->
          Repo.rollback(:stale_connection)

        execution.state != "active" ->
          Repo.rollback(:execution_fenced)

        DateTime.compare(now, execution.deadline_at) != :lt ->
          {decision, changed, event} = expire(execution, now)
          {Map.put(decision, :permitted, false), changed, event}

        is_nil(execution.provider_session_id) ->
          Repo.rollback(:identity_unconfirmed)

        not match?(%Turn{status: "running"}, Repo.get(Turn, execution.turn_id)) ->
          Repo.rollback(:turn_not_running)

        not current_binding?(execution) ->
          Repo.rollback(:ownership_changed)

        true ->
          {%{permitted: true, execution: execution}, nil, nil}
      end
    end)
  end

  @doc """
  May this actor still handle its own messages? One unlocked read.

  Deliberately not `_unsafe_authorize_write/3`. That one is a transaction with
  `FOR UPDATE` on the conversation, the journal row and the turn, and it belongs
  where a provider write or a terminal outcome actually happens — the transport
  (#1748) and `_unsafe_complete/3`. Running it per inbound message meant six
  queries and three row locks for every `{:stdout, ...}` chunk and every
  `{:acp, ...}` report of a chatty turn, and because it took the parent lock it
  serialized against admission, release, reset and the coordinator's own expire:
  the hotter the turn, the longer the coordinator queued behind the very turn it
  was supposed to expire.

  The inbound stream cannot reach the provider by itself, so it does not need
  write authorization — only "is this still mine, and is it still inside its
  deadline". Three columns answer that. `:retire` is not the durable decision
  either: the caller's retirement takes the locks and `_unsafe_complete/3`
  arbitrates completion against expiry there, so a missing row, a superseded
  connection, a closed state and a passed deadline all converge on the same
  authoritative write one frame later.
  """
  def _unsafe_actor_gate(id, connection_id, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())

    case Repo.one(
           from e in TurnExecution,
             where: e.id == ^id,
             select: %{
               state: e.state,
               connection_id: e.connection_id,
               deadline_at: e.deadline_at
             }
         ) do
      %{state: "active", connection_id: ^connection_id, deadline_at: deadline} ->
        if DateTime.compare(now, deadline) == :lt, do: :ok, else: :retire

      _ ->
        :retire
    end
  end

  @doc "A completion after the absolute deadline becomes a failed, fenced turn."
  def _unsafe_complete(id, status, opts \\ []) when status in @terminal_turns do
    with_execution(id, fn execution ->
      complete(execution, status, Keyword.get(opts, :now, DateTime.utc_now()))
    end)
  end

  @doc """
  Serialize the existing turn writer with deadline and termination state.

  This runs on **every** turn write, bounded or not — `Pending` writes a
  permission request through it on each ask, and `TurnMachine` writes a prompt
  id, a model selection and the turn's end. The unbounded path therefore pays
  one indexed lookup on `turn_executions.turn_id` (unique index) and nothing
  else: no row, no transaction, straight through to `writer`. That cost is
  deliberate, and it is the price of the guarantee being structural — a caller
  that forgets to consult the journal cannot exist, because there is only one
  turn writer and it consults the journal itself.
  """
  def _unsafe_write_turn(%Turn{} = turn, attrs, writer) do
    case Repo.get_by(TurnExecution, turn_id: turn.id) do
      nil ->
        writer.(turn, attrs)

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()
          requested_status = attrs[:status] || attrs["status"]

          {decision, changed, event} =
            cond do
              requested_status in @terminal_turns ->
                complete(current, requested_status, now)

              current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt ->
                expire(current, now)

              true ->
                {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}
            end

          row = decision.turn || Repo.rollback(:turn_missing)

          protected =
            if decision.execution.state == "active",
              do: [],
              else: [:status, :exit_code, :ended_at, :pending_permission, :limit_reason]

          protected =
            if Map.get(decision, :terminal_changed, false),
              do: List.delete(protected, :exit_code),
              else: protected

          protected = protected ++ Enum.map(protected, &Atom.to_string/1)

          case writer.(row, Map.drop(attrs, protected)) do
            {:ok, result} -> {result, changed, event}
            {:error, reason} -> Repo.rollback(reason)
          end
        end)
    end
  end

  defp complete(execution, status, now) do
    turn = lock_turn(execution.turn_id)

    cond do
      is_nil(turn) and execution.state == "active" ->
        missing_turn(execution)

      is_nil(turn) ->
        {%{execution: execution, turn: nil}, nil, nil}

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt ->
        expire(execution, now)

      execution.state == "active" and not is_nil(execution.spawn_submitted_at) and
          is_nil(execution.provider_session_id) ->
        uncertain_spawn(execution, turn, now)

      execution.state == "active" and turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      execution.state == "active" and turn.status == "completed" ->
        stop(execution, turn, "completed", now)

      execution.state == "active" and status in ["failed", "interrupted"] ->
        stop(execution, turn, status, now)

      execution.state == "active" and status == "completed" and
          is_nil(execution.provider_session_id) ->
        Repo.rollback(:execution_not_started)

      execution.state == "active" and DateTime.compare(now, execution.deadline_at) == :lt ->
        stop(execution, turn, status, now)

      true ->
        {%{execution: execution, turn: Repo.get(Turn, execution.turn_id)}, nil, nil}
    end
  end

  def _unsafe_expire(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      if execution.state == "active" and DateTime.compare(now, execution.deadline_at) != :lt do
        expire(execution, now)
      else
        {%{execution: execution, turn: Repo.get(Turn, execution.turn_id)}, nil, nil}
      end
    end)
  end

  @doc "Serialize a terminal stage with expiration; reuse an existing deadline event."
  def _unsafe_terminal_stage(conv_id, turn_id, writer) do
    case Repo.get_by(TurnExecution, conversation_id: conv_id, turn_id: turn_id) do
      nil ->
        {:ok, {:new, writer.()}}

      execution ->
        with_execution(execution.id, fn current ->
          now = DateTime.utc_now()

          {decision, changed, event} =
            if current.state == "active" and DateTime.compare(now, current.deadline_at) != :lt,
              do: expire(current, now),
              else: {%{execution: current, turn: lock_turn(current.turn_id)}, nil, nil}

          result =
            if is_nil(decision.turn) || decision.execution.deadline_event_id ||
                 (decision.turn && decision.turn.limit_reason == "wall_time_limit") do
              id = decision.execution.deadline_event_id

              stored =
                if id,
                  do: Repo.get_by(LogEvent, id: id, conversation_id: conv_id, turn_id: turn_id)

              {:existing, stored}
            else
              {:new, writer.()}
            end

          {result, changed, event}
        end)
    end
  end

  @doc "Persist one provider-write attempt; never replay a submitted or uncertain attempt."
  def _unsafe_claim_termination(id, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        execution.state != "ready" ->
          Repo.rollback(:not_ready)

        not cleanup_binding?(execution) ->
          updated = update!(execution, %{state: "uncertain", last_error: "ownership_changed"})
          {%{permitted: false, execution: updated}, updated, "termination_uncertain"}

        true ->
          updated =
            update!(execution, %{
              state: "submitted",
              attempt_id: Ecto.UUID.generate(),
              submitted_at: now
            })

          {%{permitted: true, execution: updated}, updated, "termination_submitted"}
      end
    end)
  end

  @doc "Apply only the result of the recorded attempt, including a late acknowledgment."
  def _unsafe_record_termination(id, attempt_id, result, opts \\ []) do
    with_execution(id, fn execution ->
      now = Keyword.get(opts, :now, DateTime.utc_now())

      cond do
        is_nil(attempt_id) or execution.attempt_id != attempt_id ->
          Repo.rollback(:stale_attempt)

        execution.state == "stopped" and result == :ok ->
          {execution, nil, nil}

        execution.state not in ["submitted", "uncertain"] ->
          Repo.rollback(:execution_closed)

        execution.state == "uncertain" and execution.last_error != "termination_unconfirmed" ->
          Repo.rollback(:binding_uncertain)

        result == :ok ->
          updated = update!(execution, %{state: "stopped", confirmed_at: now, last_error: nil})
          {updated, updated, "termination_confirmed"}

        true ->
          updated =
            update!(execution, %{state: "uncertain", last_error: "termination_unconfirmed"})

          {updated, updated, "termination_uncertain"}
      end
    end)
  end

  @doc "Recover lost termination owners without authorizing another provider write."
  def _unsafe_recover_submissions(%DateTime{} = cutoff, limit \\ 50) when limit in 1..100 do
    ids =
      Repo.all(
        from e in TurnExecution,
          where: e.state == "submitted" and e.submitted_at <= ^cutoff,
          order_by: [asc: e.submitted_at, asc: e.id],
          limit: ^limit,
          select: e.id
      )

    Enum.map(ids, fn id ->
      with_execution(id, fn execution ->
        if execution.state == "submitted" and
             DateTime.compare(execution.submitted_at, cutoff) != :gt do
          updated =
            update!(execution, %{state: "uncertain", last_error: "termination_unconfirmed"})

          {updated, updated, "termination_uncertain"}
        else
          {execution, nil, nil}
        end
      end)
    end)
  end

  @doc """
  Write off an obligation nothing can resolve, without ever replaying it.

  `awaiting_identity` and `uncertain` are reached when the provider never named
  the session, named two, or left a termination unacknowledged. Nothing can move
  them on its own: a claim needs `ready`, and an acknowledgment needs the
  `attempt_id` of an attempt whose owner is gone. Left alone they fence their
  conversation and their machine for good, which costs an owner the two
  recoveries — a new turn, and `reset_sandbox/2` — that exist for exactly this.

  So the fence is an obligation with an age, not a life sentence. Past `cutoff`
  the row retires to `stopped` and keeps `last_error`, so the trail still says
  the operation was never confirmed. This authorizes no provider write; it gives
  up on one. A session that really did survive is the `SandboxReaper`'s to find,
  the same as every unbounded turn's.
  """
  def _unsafe_retire_unresolved(%DateTime{} = cutoff, limit \\ 50) when limit in 1..100 do
    ids =
      Repo.all(
        from e in TurnExecution,
          where: e.state in ["awaiting_identity", "uncertain"] and e.updated_at <= ^cutoff,
          order_by: [asc: e.updated_at, asc: e.id],
          limit: ^limit,
          select: e.id
      )

    Enum.map(ids, fn id ->
      with_execution(id, fn execution ->
        if execution.state in ["awaiting_identity", "uncertain"] and
             DateTime.compare(execution.updated_at, cutoff) != :gt do
          updated =
            update!(execution, %{
              state: "stopped",
              last_error: execution.last_error || "unresolved_obligation_expired"
            })

          {updated, updated, "obligation_abandoned"}
        else
          {execution, nil, nil}
        end
      end)
    end)
  end

  @doc "Rows needing deadline or termination handling; this read grants no provider write."
  def _unsafe_due(now \\ DateTime.utc_now(), limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: (e.state == "active" and e.deadline_at <= ^now) or e.state == "ready",
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit
    )
  end

  @doc "Deadline candidates only; pending provider cleanup must not starve expiration."
  def _unsafe_due_deadlines(now, limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: e.state == "active" and e.deadline_at <= ^now,
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit,
        select: e.id
    )
  end

  @doc "Known sessions awaiting their one termination claim, independently of deadlines."
  def _unsafe_ready_terminations(limit \\ 50) when limit in 1..100 do
    Repo.all(
      from e in TurnExecution,
        where: e.state == "ready",
        order_by: [asc: e.deadline_at, asc: e.id],
        limit: ^limit,
        select: e.id
    )
  end

  @doc "Unfinished remote work also prevents reset after its local turn has ended."
  def _unsafe_sandbox_open?(sandbox_id) do
    Repo.exists?(
      from e in TurnExecution,
        where: e.sandbox_id == ^sandbox_id and e.state not in ["completed", "stopped"]
    )
  end

  def _unsafe_fenced?(conversation_id) do
    Repo.exists?(
      from e in TurnExecution,
        where: e.conversation_id == ^conversation_id and e.state in ^@fenced
    )
  end

  defp expire(execution, now) do
    turn = lock_turn(execution.turn_id)

    # A different completion path may already have ended the row. It cannot
    # authorize terminating the connection now used by a later turn.
    cond do
      is_nil(turn) ->
        missing_turn(execution)

      turn.status in ["failed", "interrupted"] ->
        stop(execution, turn, turn.status, now)

      turn.status == "completed" ->
        stop(execution, turn, "completed", now)

      true ->
        state =
          cond do
            execution.provider_session_id -> "ready"
            execution.spawn_submitted_at -> "awaiting_identity"
            true -> "stopped"
          end

        updated = update!(execution, %{state: state})

        turn =
          update!(turn, %{
            status: "failed",
            limit_reason: "wall_time_limit",
            exit_code: nil,
            ended_at: DateTime.truncate(now, :second),
            pending_permission: nil
          })

        # ownership: expire holds the original journal, parent and turn locks;
        # the event writer also checks the parent against the saved tenant.
        event_id = DeadlineEvents._unsafe_record!(updated, turn)
        updated = update!(updated, %{deadline_event_id: event_id})

        {%{execution: updated, turn: turn}, updated, "deadline_expired"}
    end
  end

  # No local turn outcome proves the command stopped. Even a successful reply
  # may leave background work; every bounded connection requires remote cleanup.
  defp stop(execution, turn, status, now) do
    state =
      cond do
        execution.provider_session_id -> "ready"
        execution.spawn_submitted_at -> "awaiting_identity"
        true -> "stopped"
      end

    updated = update!(execution, %{state: state})
    changed = turn.status == "running"

    turn =
      if changed,
        do:
          update!(turn, %{
            status: status,
            ended_at: DateTime.truncate(now, :second),
            pending_permission: nil
          }),
        else: turn

    {%{execution: updated, turn: turn, terminal_changed: changed}, updated, "stop_requested"}
  end

  defp uncertain_spawn(execution, turn, now) do
    updated = update!(execution, %{state: "awaiting_identity", last_error: "spawn_unconfirmed"})

    turn =
      update!(turn, %{
        status: "failed",
        exit_code: nil,
        pending_permission: nil,
        ended_at: DateTime.truncate(now, :second)
      })

    {%{execution: updated, turn: turn}, updated, "spawn_uncertain"}
  end

  defp missing_turn(execution) do
    updated = update!(execution, %{state: "uncertain", last_error: "turn_missing"})
    {%{execution: updated, turn: nil}, updated, "termination_uncertain"}
  end

  defp fail_running_turn(turn_id, now) do
    case lock_turn(turn_id) do
      %Turn{status: "running"} = turn ->
        update!(turn, %{
          status: "failed",
          exit_code: nil,
          pending_permission: nil,
          ended_at: DateTime.truncate(now, :second)
        })

      _ ->
        :ok
    end
  end

  # A persisted retirement survives parent deletion. The original sandbox row
  # must still prove its tenant/name/provider binding; a surviving conversation
  # must also remain bound to it. Missing or changed sandbox identity stays
  # uncertain. Reset cannot reuse this row while its journal remains open.
  defp cleanup_binding?(execution) do
    sandbox_matches =
      Repo.exists?(
        from s in Sandbox,
          where:
            s.id == ^execution.sandbox_id and s.user_id == ^execution.user_id and
              s.sprite_name == ^execution.sandbox_name and s.provider == ^execution.provider
      )

    parent_matches =
      case Repo.get(Conversation, execution.conversation_id) do
        nil -> true
        conv -> conv.user_id == execution.user_id and conv.sandbox_id == execution.sandbox_id
      end

    sandbox_matches and parent_matches
  end

  defp current_binding?(execution) do
    Repo.exists?(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where:
          c.id == ^execution.conversation_id and c.user_id == ^execution.user_id and
            s.id == ^execution.sandbox_id and s.user_id == ^execution.user_id and
            s.sprite_name == ^execution.sandbox_name and s.provider == ^execution.provider and
            s.status not in ["failed", "terminated"]
    )
  end

  defp with_execution(id, fun) do
    transaction(fn ->
      existing = Repo.get(TurnExecution, id) || Repo.rollback(:not_found)
      lock_parent(existing.conversation_id)
      execution = Repo.one!(from e in TurnExecution, where: e.id == ^id, lock: "FOR UPDATE")
      # Acquire every row lock before callbacks read the clock. A legacy writer
      # holding just the turn row must not extend a completion or spawn deadline.
      lock_turn(execution.turn_id)
      fun.(execution)
    end)
  end

  # Same namespace/order as sandbox reset: machine lock, then parent, then journal.
  # The reset retires its row under this lock before any provider I/O.
  defp lock_sandbox(id) do
    Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [4316, :erlang.phash2(id)])
  end

  defp lock_parent(id),
    do: Repo.one(from c in Conversation, where: c.id == ^id, lock: "FOR UPDATE")

  defp lock_execution_by_turn(id),
    do: Repo.one(from e in TurnExecution, where: e.turn_id == ^id, lock: "FOR UPDATE")

  defp lock_turn(id),
    do: Repo.one(from t in Turn, where: t.id == ^id, lock: "FOR UPDATE")

  defp prior_connection(connection_id),
    do:
      Repo.one(
        from e in TurnExecution,
          where: e.connection_id == ^connection_id,
          order_by: [desc: e.inserted_at],
          limit: 1
      )

  defp open_execution?(conversation_id),
    do:
      Repo.exists?(
        from e in TurnExecution,
          where: e.conversation_id == ^conversation_id and e.state not in ["completed", "stopped"]
      )

  # The allowance this turn is admitted under, resolved once under the parent
  # lock and frozen onto the journal row. The saved conversation allowance is
  # `execution_allowances` (#1790), not a column on the parent: it carries a
  # revision, so a launch and a resume cannot silently overwrite each other.
  #
  # `for_new_turn/3` tightens rather than re-resolves — a later turn may be
  # narrower than the saved allowance but never wider, so raising an account
  # ceiling mid-conversation does not widen a conversation that was already
  # admitted under a lower one.
  defp resolve_turn_limits(conv) do
    user = Repo.get!(Fountain.Accounts.User, conv.user_id)

    saved = saved_allowance(conv.id)

    case ExecutionLimits.for_new_turn(
           ExecutionLimits.host_ceiling(),
           user.execution_limits,
           saved
         ) do
      {:ok, limits} -> limits
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp saved_allowance(conversation_id) do
    case Repo.one(
           from a in Fountain.Conversations.ExecutionAllowance,
             where: a.conversation_id == ^conversation_id,
             select: a.limits
         ) do
      nil -> %{}
      limits when is_map(limits) -> limits
      _ -> Repo.rollback({:execution_limits_invalid, "object_required"})
    end
  end

  # A journal row's deadline is absolute, so the wall-clock allowance is checked
  # against it here rather than trusted from the caller that computed it. A
  # caller that asks for a deadline beyond the allowance is refused, not clamped
  # — silently shortening someone's requested bound is the worse answer.
  defp enforce_deadline_ceiling!(turn, deadline_at, %{"wall_time_seconds" => seconds}) do
    if is_nil(turn.started_at), do: Repo.rollback(:turn_not_started)
    ceiling = DateTime.add(turn.started_at, seconds, :second)

    if DateTime.compare(deadline_at, ceiling) == :gt,
      do: Repo.rollback({:execution_limits_widen, "wall_time_seconds"})
  end

  defp enforce_deadline_ceiling!(_turn, _deadline_at, _limits), do: :ok

  # A session id is interpolated into a provider termination request, so it is
  # validated as an opaque token rather than trusted as a string: unreserved
  # URL characters only (RFC 3986 minus `.` and `~`), bounded length. Every
  # session id the pinned adapters issue is a UUID or a base62 token, and both
  # fit. This is deliberately narrower than "what a provider might send" — a
  # rejected identity fails loudly at bind time, where the turn is still the
  # owner's to retry, and that is the better half of the trade against a
  # separator reaching a URL path.
  defp valid_session_id?(id),
    do: is_binary(id) and byte_size(id) in 1..256 and Regex.match?(~r/\A[A-Za-z0-9_-]+\z/, id)

  defp update!(%TurnExecution{} = row, attrs),
    do: row |> TurnExecution.changeset(attrs) |> Repo.update!()

  defp update!(%Turn{} = row, attrs), do: row |> Turn.changeset(attrs) |> Repo.update!()

  defp record_event(execution, event) do
    Audit.record(%{
      user_id: execution.user_id,
      action: "conversation.execution_#{event}",
      resource_type: "conversation",
      resource_id: execution.conversation_id,
      actor: "system:turn_deadline",
      metadata: %{"turn_id" => execution.turn_id}
    })
  end

  defp transaction(fun) do
    case Repo.transaction(fun) do
      {:ok, {result, execution, event}} ->
        if event, do: record_event(execution, event)

        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
